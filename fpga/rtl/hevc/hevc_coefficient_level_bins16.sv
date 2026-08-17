module hevc_coefficient_level_bins16 #(
    parameter bit CHROMA = 1'b0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_nonzero,
    input  logic [3:0]         s_group_scan_position,
    input  logic               s_block_start,
    input  logic               s_group_end,
    input  logic               s_block_last,
    output logic               m_valid,
    input  logic               m_ready,
    output logic               m_bin,
    output logic               m_bypass,
    output logic [1:0]         m_kind,
    output logic [4:0]         m_context_index,
    output logic [3:0]         m_group_scan_position,
    output logic [3:0]         m_coefficient_index,
    output logic               group_done,
    output logic               block_done,
    output logic               busy,
    output logic               input_error
);
    localparam logic [1:0] KIND_GREATER1 = 2'd0;
    localparam logic [1:0] KIND_GREATER2 = 2'd1;
    localparam logic [1:0] KIND_SIGN = 2'd2;
    localparam logic [1:0] KIND_REMAINING = 2'd3;

    typedef enum logic [3:0] {
        COLLECT, LOAD_GREATER1, GREATER1, GREATER2, SIGN_BITS,
        REMAIN_SETUP, REMAIN_CALCULATE, REMAIN_ESCAPE,
        RICE_PREFIX, RICE_SUFFIX,
        REMAIN_ADVANCE, FINISH
    } state_t;
    state_t state;

    // Efinity EBRs have synchronous read ports.  Two mirrored stores preserve
    // the two independent read addresses used by the event walker and c2 bin
    // without creating a combinational RAM-to-CABAC path.
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [15:0] event_magnitudes [0:15];
    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    logic [15:0] c2_magnitudes [0:15];
    logic signs [0:15];
    logic [4:0] collect_count;
    logic [4:0] group_count;
    logic [3:0] active_group;
    logic pending_block_last;

    logic [1:0] carried_c1;
    logic [1:0] c1;
    logic [1:0] context_set;
    logic first_c2_valid;
    logic [3:0] first_c2_index;
    logic [4:0] event_index;

    logic first_coefficient2;
    logic [2:0] rice_parameter;
    logic [4:0] prefix_ones_remaining;
    logic [4:0] suffix_width;
    logic [4:0] suffix_index;
    logic [15:0] suffix_value;
    logic [15:0] remaining_symbol_register;
    logic [15:0] escape_value_base_register;
    logic [4:0] escape_length_register;
    logic [3:0] event_read_address;
    logic [3:0] c2_read_address;
    logic [15:0] event_magnitude;
    logic [15:0] c2_magnitude;

    wire [15:0] coefficient_bits = s_coefficient;
    wire [15:0] input_magnitude = coefficient_bits[15] ?
        ((~coefficient_bits) + 16'd1) : coefficient_bits;
    wire [4:0] final_collect_count =
        collect_count + (s_nonzero ? 5'd1 : 5'd0);

    wire [4:0] greater1_count = (group_count > 5'd8) ?
                                5'd8 : group_count;
    wire magnitude_write_enable = (state == COLLECT) && s_valid &&
        s_nonzero && (collect_count < 5'd16);
    wire [15:0] current_magnitude = event_magnitude;
    wire current_greater1 = (current_magnitude > 16'd1);
    wire [1:0] next_c1 = current_greater1 ? 2'd0 :
                         ((c1 > 0 && c1 < 3) ? c1 + 1'b1 : c1);

    wire [15:0] current_base_level = (event_index < 5'd8) ?
        (16'd2 + {15'd0, first_coefficient2}) : 16'd1;
    wire current_has_remaining = (current_magnitude >= current_base_level);
    wire [15:0] remaining_symbol = current_magnitude - current_base_level;
    wire [15:0] rice_threshold = 16'd3 << rice_parameter;

    function automatic logic [4:0] escape_length(
        input logic [15:0] value_base
    );
        begin
            casez (value_base)
                16'b1???????????????: escape_length = 5'd15;
                16'b01??????????????: escape_length = 5'd14;
                16'b001?????????????: escape_length = 5'd13;
                16'b0001????????????: escape_length = 5'd12;
                16'b00001???????????: escape_length = 5'd11;
                16'b000001??????????: escape_length = 5'd10;
                16'b0000001?????????: escape_length = 5'd9;
                16'b00000001????????: escape_length = 5'd8;
                16'b000000001???????: escape_length = 5'd7;
                16'b0000000001??????: escape_length = 5'd6;
                16'b00000000001?????: escape_length = 5'd5;
                16'b000000000001????: escape_length = 5'd4;
                16'b0000000000001???: escape_length = 5'd3;
                16'b00000000000001??: escape_length = 5'd2;
                16'b000000000000001?: escape_length = 5'd1;
                default:              escape_length = 5'd0;
            endcase
        end
    endfunction

    function automatic logic [4:0] rice_quotient(
        input logic [8:0] symbol,
        input logic [2:0] rice_param
    );
        case (rice_param)
            3'd0: rice_quotient = symbol[4:0];
            3'd1: rice_quotient = symbol[5:1];
            3'd2: rice_quotient = symbol[6:2];
            3'd3: rice_quotient = symbol[7:3];
            default: rice_quotient = symbol[8:4];
        endcase
    endfunction

    wire registered_normal_rice =
        (remaining_symbol_register < rice_threshold);
    wire [15:0] calculated_escape_base =
        remaining_symbol_register - (16'd2 << rice_parameter);
    wire [4:0] calculated_escape_length =
        escape_length(calculated_escape_base);
    wire [4:0] normal_rice_quotient =
        rice_quotient(remaining_symbol_register[8:0], rice_parameter);

    always_comb begin
        event_read_address = event_index[3:0];
        c2_read_address = first_c2_index;
        case (state)
            LOAD_GREATER1: event_read_address = 4'd0;
            GREATER1: begin
                if (m_valid && m_ready &&
                        (event_index + 1'b1 < greater1_count))
                    event_read_address = event_index[3:0] + 1'b1;
                if (current_greater1 && !first_c2_valid)
                    c2_read_address = event_index[3:0];
            end
            SIGN_BITS: begin
                if (m_valid && m_ready &&
                        (event_index + 1'b1 >= group_count))
                    event_read_address = 4'd0;
            end
            REMAIN_SETUP: begin
                if ((event_index < group_count) && !current_has_remaining)
                    event_read_address = event_index[3:0] + 1'b1;
            end
            REMAIN_ADVANCE:
                event_read_address = event_index[3:0] + 1'b1;
            default: begin
            end
        endcase
    end

    // Separate clocked read/write processes match Efinity's simple-dual-port
    // block-RAM inference template.  Both copies receive identical writes.
    always_ff @(posedge clk) begin
        if (magnitude_write_enable)
            event_magnitudes[collect_count[3:0]] <= input_magnitude;
    end

    always_ff @(posedge clk) begin
        if (magnitude_write_enable)
            c2_magnitudes[collect_count[3:0]] <= input_magnitude;
    end

    always_ff @(posedge clk) begin
        event_magnitude <= event_magnitudes[event_read_address];
        c2_magnitude <= c2_magnitudes[c2_read_address];
    end

    always_comb begin
        s_ready = (state == COLLECT);
        m_valid = 1'b0;
        m_bin = 1'b0;
        m_bypass = 1'b0;
        m_kind = KIND_GREATER1;
        m_context_index = 5'd0;
        m_group_scan_position = active_group;
        m_coefficient_index = event_index[3:0];
        busy = (state != COLLECT);

        case (state)
            GREATER1: begin
                m_valid = 1'b1;
                m_bin = current_greater1;
                m_context_index =
                    ({3'd0, context_set} << 2) + {3'd0, c1};
            end
            GREATER2: begin
                m_valid = (c1 == 0) && first_c2_valid;
                m_bin = (c2_magnitude > 16'd2);
                m_kind = KIND_GREATER2;
                m_context_index = {3'd0, context_set};
                m_coefficient_index = first_c2_index;
            end
            SIGN_BITS: begin
                m_valid = 1'b1;
                m_bin = signs[event_index[3:0]];
                m_bypass = 1'b1;
                m_kind = KIND_SIGN;
            end
            RICE_PREFIX: begin
                m_valid = 1'b1;
                m_bin = (prefix_ones_remaining != 0);
                m_bypass = 1'b1;
                m_kind = KIND_REMAINING;
            end
            RICE_SUFFIX: begin
                m_valid = 1'b1;
                m_bin = suffix_value[suffix_index[3:0]];
                m_bypass = 1'b1;
                m_kind = KIND_REMAINING;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= COLLECT;
            collect_count <= '0;
            group_count <= '0;
            active_group <= '0;
            pending_block_last <= 1'b0;
            carried_c1 <= 2'd1;
            c1 <= 2'd1;
            context_set <= '0;
            first_c2_valid <= 1'b0;
            first_c2_index <= '0;
            event_index <= '0;
            first_coefficient2 <= 1'b1;
            rice_parameter <= '0;
            prefix_ones_remaining <= '0;
            suffix_width <= '0;
            suffix_index <= '0;
            suffix_value <= '0;
            remaining_symbol_register <= '0;
            escape_value_base_register <= '0;
            escape_length_register <= '0;
            group_done <= 1'b0;
            block_done <= 1'b0;
            input_error <= 1'b0;
        end else begin
            group_done <= 1'b0;
            block_done <= 1'b0;
            case (state)
                COLLECT: begin
                    if (s_valid) begin
                        if (s_block_start) begin
                            carried_c1 <= 2'd1;
                            input_error <= 1'b0;
                        end
                        if (s_nonzero) begin
                            if (collect_count < 5'd16) begin
                                signs[collect_count[3:0]] <= coefficient_bits[15];
                            end else begin
                                input_error <= 1'b1;
                            end
                            collect_count <= collect_count + 1'b1;
                        end
                        if (s_group_end) begin
                            active_group <= s_group_scan_position;
                            group_count <= final_collect_count;
                            pending_block_last <= s_block_last;
                            collect_count <= '0;
                            if (final_collect_count == 0) begin
                                group_done <= 1'b1;
                                block_done <= s_block_last;
                            end else begin
                                context_set <=
                                    ((!CHROMA && (s_group_scan_position > 0)) ?
                                     2'd2 : 2'd0) +
                                    (((s_block_start ? 2'd1 : carried_c1) == 0) ?
                                     2'd1 : 2'd0);
                                c1 <= 2'd1;
                                first_c2_valid <= 1'b0;
                                first_c2_index <= '0;
                                event_index <= '0;
                                state <= LOAD_GREATER1;
                            end
                        end
                    end
                end
                LOAD_GREATER1: begin
                    state <= GREATER1;
                end
                GREATER1: begin
                    if (m_valid && m_ready) begin
                        c1 <= next_c1;
                        if (current_greater1 && !first_c2_valid) begin
                            first_c2_valid <= 1'b1;
                            first_c2_index <= event_index[3:0];
                        end
                        if (event_index + 1'b1 >= greater1_count) begin
                            carried_c1 <= next_c1;
                            event_index <= '0;
                            state <= GREATER2;
                        end else begin
                            event_index <= event_index + 1'b1;
                        end
                    end
                end
                GREATER2: begin
                    if (!((c1 == 0) && first_c2_valid) ||
                            (m_valid && m_ready)) begin
                        event_index <= '0;
                        state <= SIGN_BITS;
                    end
                end
                SIGN_BITS: begin
                    if (m_valid && m_ready) begin
                        if (event_index + 1'b1 >= group_count) begin
                            event_index <= '0;
                            first_coefficient2 <= 1'b1;
                            rice_parameter <= '0;
                            if ((c1 == 0) || (group_count > 5'd8)) begin
                                state <= REMAIN_SETUP;
                            end else begin
                                state <= FINISH;
                            end
                        end else begin
                            event_index <= event_index + 1'b1;
                        end
                    end
                end
                REMAIN_SETUP: begin
                    if (event_index >= group_count) begin
                        state <= FINISH;
                    end else if (current_has_remaining) begin
                        remaining_symbol_register <= remaining_symbol;
                        state <= REMAIN_CALCULATE;
                    end else begin
                        if (current_magnitude >= 16'd2) begin
                            first_coefficient2 <= 1'b0;
                        end
                        event_index <= event_index + 1'b1;
                    end
                end
                REMAIN_CALCULATE: begin
                    if (registered_normal_rice) begin
                        prefix_ones_remaining <= normal_rice_quotient;
                        suffix_width <= {2'd0, rice_parameter};
                        suffix_value <= remaining_symbol_register;
                        state <= RICE_PREFIX;
                    end else begin
                        // Register priority-encoder results before the dynamic
                        // shift/subtract used to form the escape suffix.
                        escape_value_base_register <= calculated_escape_base;
                        escape_length_register <= calculated_escape_length;
                        state <= REMAIN_ESCAPE;
                    end
                end
                REMAIN_ESCAPE: begin
                    prefix_ones_remaining <=
                        5'd3 + escape_length_register -
                        {2'd0, rice_parameter};
                    suffix_width <= escape_length_register;
                    suffix_value <= escape_value_base_register -
                        (16'd1 << escape_length_register);
                    state <= RICE_PREFIX;
                end
                RICE_PREFIX: begin
                    if (m_valid && m_ready) begin
                        if (prefix_ones_remaining != 0) begin
                            prefix_ones_remaining <= prefix_ones_remaining - 1'b1;
                        end else if (suffix_width != 0) begin
                            suffix_index <= suffix_width - 1'b1;
                            state <= RICE_SUFFIX;
                        end else begin
                            state <= REMAIN_ADVANCE;
                        end
                    end
                end
                RICE_SUFFIX: begin
                    if (m_valid && m_ready) begin
                        if (suffix_index == 0) begin
                            state <= REMAIN_ADVANCE;
                        end else begin
                            suffix_index <= suffix_index - 1'b1;
                        end
                    end
                end
                REMAIN_ADVANCE: begin
                    if (current_magnitude > rice_threshold &&
                            rice_parameter < 3'd4) begin
                        rice_parameter <= rice_parameter + 1'b1;
                    end
                    if (current_magnitude >= 16'd2) begin
                        first_coefficient2 <= 1'b0;
                    end
                    event_index <= event_index + 1'b1;
                    state <= REMAIN_SETUP;
                end
                default: begin
                    group_done <= 1'b1;
                    block_done <= pending_block_last;
                    state <= COLLECT;
                end
            endcase
        end
    end
endmodule
