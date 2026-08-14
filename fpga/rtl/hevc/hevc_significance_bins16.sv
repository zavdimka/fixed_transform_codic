module hevc_significance_bins16 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic [7:0]         s_scan_position,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_group_nonzero,
    input  logic [15:0]        s_significant_group_flags,
    input  logic               s_block_last,
    output logic               m_valid,
    input  logic               m_ready,
    output logic               m_bin,
    output logic               m_coded_sub_block,
    output logic [4:0]         m_context_index,
    output logic [7:0]         m_scan_position,
    output logic               m_syntax_last,
    output logic               stage_done,
    output logic               busy,
    output logic               input_error
);
    typedef enum logic [1:0] {START, COEFFICIENT, GROUP_FLAG} state_t;
    state_t state;

    logic [3:0] current_group;
    logic [3:0] last_group;
    logic [4:0] nonzero_in_group;
    logic [15:0] group_flags;

    function automatic logic [3:0] diagonal4(input logic [3:0] index);
        case (index)
            4'd0: diagonal4 = 4'd0;
            4'd1: diagonal4 = 4'd4;
            4'd2: diagonal4 = 4'd1;
            4'd3: diagonal4 = 4'd8;
            4'd4: diagonal4 = 4'd5;
            4'd5: diagonal4 = 4'd2;
            4'd6: diagonal4 = 4'd12;
            4'd7: diagonal4 = 4'd9;
            4'd8: diagonal4 = 4'd6;
            4'd9: diagonal4 = 4'd3;
            4'd10: diagonal4 = 4'd13;
            4'd11: diagonal4 = 4'd10;
            4'd12: diagonal4 = 4'd7;
            4'd13: diagonal4 = 4'd14;
            4'd14: diagonal4 = 4'd11;
            default: diagonal4 = 4'd15;
        endcase
    endfunction

    function automatic logic significant_group_context(
        input logic [15:0] flags,
        input logic [3:0] group_raster
    );
        logic right;
        logic lower;
        begin
            right = (group_raster[1:0] < 2'd3) &&
                    flags[group_raster + 1'b1];
            lower = (group_raster[3:2] < 2'd3) &&
                    flags[group_raster + 3'd4];
            significant_group_context = right || lower;
        end
    endfunction

    function automatic logic [4:0] significant_coefficient_context(
        input logic [15:0] flags,
        input logic [7:0] raster_address
    );
        logic [3:0] x;
        logic [3:0] y;
        logic [1:0] group_x;
        logic [1:0] group_y;
        logic [3:0] group_raster;
        logic right;
        logic lower;
        logic [1:0] pattern;
        logic [1:0] local_x;
        logic [1:0] local_y;
        logic [2:0] local_sum;
        logic [1:0] count;
        begin
            x = raster_address[3:0];
            y = raster_address[7:4];
            if ((x + y) == 0) begin
                significant_coefficient_context = 5'd0;
            end else begin
                group_x = x[3:2];
                group_y = y[3:2];
                group_raster = {group_y, group_x};
                right = (group_x < 2'd3) && flags[group_raster + 1'b1];
                lower = (group_y < 2'd3) && flags[group_raster + 3'd4];
                pattern = {lower, right};
                local_x = x[1:0];
                local_y = y[1:0];
                local_sum = local_x + local_y;
                case (pattern)
                    2'd0: count = (local_sum == 0) ? 2'd2 :
                                    ((local_sum <= 2) ? 2'd1 : 2'd0);
                    2'd1: count = (local_y == 0) ? 2'd2 :
                                    ((local_y == 1) ? 2'd1 : 2'd0);
                    2'd2: count = (local_x == 0) ? 2'd2 :
                                    ((local_x == 1) ? 2'd1 : 2'd0);
                    default: count = 2'd2;
                endcase
                significant_coefficient_context =
                    5'd21 + ((group_x + group_y > 0) ? 5'd3 : 5'd0) + {3'd0, count};
            end
        end
    endfunction

    wire [3:0] input_group = s_scan_position[7:4];
    wire [3:0] input_group_raster = diagonal4(input_group);
    wire coefficient_nonzero = (s_coefficient != 0);
    wire group_is_active = (current_group == last_group) ||
                           (current_group == 0) || s_group_nonzero;
    wire coefficient_bin_required =
        (s_scan_position[3:0] != 0) ||
        (current_group == 0) ||
        (nonzero_in_group != 0);
    wire group_flag_required = (input_group != 0);

    always_comb begin
        s_ready = 1'b0;
        m_valid = 1'b0;
        m_bin = 1'b0;
        m_coded_sub_block = 1'b0;
        m_context_index = 5'd0;
        m_scan_position = s_scan_position;
        m_syntax_last = 1'b0;
        busy = (state != START);

        case (state)
            START: s_ready = 1'b1;
            COEFFICIENT: begin
                if (s_valid && input_group == current_group) begin
                    if (group_is_active && coefficient_bin_required) begin
                        m_valid = 1'b1;
                        s_ready = m_ready;
                        m_bin = coefficient_nonzero;
                        m_context_index = significant_coefficient_context(
                            group_flags, s_raster_address
                        );
                        m_syntax_last = s_block_last;
                    end else begin
                        s_ready = 1'b1;
                    end
                end
            end
            default: begin
                if (s_valid && group_flag_required) begin
                    m_valid = 1'b1;
                    m_bin = s_group_nonzero;
                    m_coded_sub_block = 1'b1;
                    m_context_index = {
                        4'd0,
                        significant_group_context(
                            group_flags, input_group_raster
                        )
                    };
                    m_scan_position = {input_group, 4'hf};
                end
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= START;
            current_group <= '0;
            last_group <= '0;
            nonzero_in_group <= '0;
            group_flags <= '0;
            stage_done <= 1'b0;
            input_error <= 1'b0;
        end else begin
            stage_done <= 1'b0;
            case (state)
                START: begin
                    if (s_valid) begin
                        current_group <= input_group;
                        last_group <= input_group;
                        nonzero_in_group <= coefficient_nonzero ? 5'd1 : 5'd0;
                        group_flags <= s_significant_group_flags;
                        input_error <= !coefficient_nonzero;
                        if (s_block_last) begin
                            stage_done <= 1'b1;
                        end else begin
                            state <= COEFFICIENT;
                        end
                    end
                end
                COEFFICIENT: begin
                    if (s_valid && input_group != current_group) begin
                        state <= GROUP_FLAG;
                    end else if (s_valid && s_ready) begin
                        if (coefficient_nonzero) begin
                            nonzero_in_group <= nonzero_in_group + 1'b1;
                        end
                        if (group_is_active && !coefficient_bin_required &&
                                !coefficient_nonzero) begin
                            input_error <= 1'b1;
                        end
                        if (s_block_last) begin
                            stage_done <= 1'b1;
                            state <= START;
                        end
                    end
                end
                default: begin
                    if (s_valid && !group_flag_required) begin
                        current_group <= input_group;
                        nonzero_in_group <= '0;
                        state <= COEFFICIENT;
                    end else if (m_valid && m_ready) begin
                        current_group <= input_group;
                        nonzero_in_group <= '0;
                        state <= COEFFICIENT;
                    end
                end
            endcase
        end
    end
endmodule
