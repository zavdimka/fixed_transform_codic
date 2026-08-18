module custom_ctu_entropy_writer36 #(
    parameter integer COUNT_WIDTH = 17,
    parameter integer TOKEN_WIDTH = 32,
    parameter integer BYTE_COUNT_WIDTH = 13,
    parameter integer FIFO_DEPTH = 4
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          start_valid,
    output logic                          start_ready,
    input  logic [COUNT_WIDTH-1:0]        base_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_limit_bits,
    input  logic [COUNT_WIDTH-1:0]        base_reserved_bits,
    input  logic [COUNT_WIDTH-1:0]        enhancement_reserved_bits,
    input  logic                          finish_valid,
    output logic                          finish_ready,
    output logic                          finish_done,

    input  logic                          prefix_valid,
    output logic                          prefix_ready,
    input  logic [1:0]                    prefix_mode,

    input  logic                          command_valid,
    output logic                          command_ready,
    input  logic                          command_quality24,
    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic signed [127:0]           s_row_a,
    input  logic signed [127:0]           s_row_b,

    output logic                          m_valid,
    input  logic                          m_ready,
    output logic                          m_layer,
    output logic [7:0]                    m_byte,
    output logic                          drop_pulse,
    output logic                          drop_layer,
    output logic                          fatal_error,
    output logic                          busy,
    output logic [COUNT_WIDTH-1:0]        base_used_bits,
    output logic [COUNT_WIDTH-1:0]        enhancement_used_bits,
    output logic [BYTE_COUNT_WIDTH-1:0]   base_byte_count,
    output logic [BYTE_COUNT_WIDTH-1:0]   enhancement_byte_count,
    output logic                          coefficient_saturated,
    output logic                          transform_done,
    output logic                          block_done,
    output logic                          pair_done,
    output logic                          ctu_done
);
    localparam integer FIFO_LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);
    logic bridge_command_ready, bridge_m_valid, bridge_m_ready;
    logic [1:0] bridge_m_op_type;
    logic bridge_m_layer, bridge_m_mandatory, bridge_m_table_class;
    logic bridge_m_table_id, bridge_m_raw_value, bridge_m_eob_required;
    logic [5:0] bridge_m_reserve_release;
    logic [7:0] bridge_m_symbol;
    logic [10:0] bridge_m_amplitude;
    logic [3:0] bridge_m_amplitude_length;
    logic [1:0] bridge_m_raw_length;
    logic bridge_m_last, bridge_busy, bridge_input_error, bridge_saturated;
    logic source_window_open, start_fire, command_fire;
    logic [1:0] accepted_pair_count;
    logic [1:0] completed_pair_count;
    logic active_quality24;
    logic pair_table_id;
    logic [5:0] pair_base_count;
    logic [FIFO_LEVEL_WIDTH-1:0] unused_fifo_level;

    // Registered elastic boundary between the scanner-bank output mux and the
    // entropy/VLC path.  Apart from cutting the longest placed route, this
    // remains a one-descriptor-per-cycle interface when both sides are ready.
    logic descriptor_valid, entropy_s_ready, entropy_finish_valid;
    logic [1:0] descriptor_op_type;
    logic descriptor_layer, descriptor_mandatory, descriptor_table_class;
    logic descriptor_table_id, descriptor_raw_value, descriptor_eob_required;
    logic descriptor_last;
    logic [5:0] descriptor_reserve_release;
    logic [7:0] descriptor_symbol;
    logic [10:0] descriptor_amplitude;
    logic [3:0] descriptor_amplitude_length;
    logic [1:0] descriptor_raw_length;

    assign start_fire = start_valid && start_ready;
    assign pair_table_id = accepted_pair_count == 2;
    assign pair_base_count = pair_table_id ? 6'd3 : 6'd6;
    assign command_ready = source_window_open
                         && (accepted_pair_count < 3)
                         && bridge_command_ready;
    assign command_fire = command_valid && command_ready;
    assign ctu_done = pair_done && (completed_pair_count == 2);
    assign bridge_m_ready = !descriptor_valid || entropy_s_ready;
    // Keep the entropy source window open long enough to drain the boundary
    // register.  finish_valid is a held ready/valid request, so delaying its
    // presentation internally cannot lose the request.
    assign entropy_finish_valid = finish_valid
                                && !bridge_busy && !descriptor_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            descriptor_valid <= 1'b0;
            descriptor_op_type <= '0;
            descriptor_layer <= 1'b0;
            descriptor_mandatory <= 1'b0;
            descriptor_reserve_release <= '0;
            descriptor_table_class <= 1'b0;
            descriptor_table_id <= 1'b0;
            descriptor_symbol <= '0;
            descriptor_amplitude <= '0;
            descriptor_amplitude_length <= '0;
            descriptor_raw_value <= 1'b0;
            descriptor_raw_length <= '0;
            descriptor_eob_required <= 1'b0;
            descriptor_last <= 1'b0;
        end else if (bridge_m_ready) begin
            descriptor_valid <= bridge_m_valid;
            if (bridge_m_valid) begin
                descriptor_op_type <= bridge_m_op_type;
                descriptor_layer <= bridge_m_layer;
                descriptor_mandatory <= bridge_m_mandatory;
                descriptor_reserve_release <= bridge_m_reserve_release;
                descriptor_table_class <= bridge_m_table_class;
                descriptor_table_id <= bridge_m_table_id;
                descriptor_symbol <= bridge_m_symbol;
                descriptor_amplitude <= bridge_m_amplitude;
                descriptor_amplitude_length <= bridge_m_amplitude_length;
                descriptor_raw_value <= bridge_m_raw_value;
                descriptor_raw_length <= bridge_m_raw_length;
                descriptor_eob_required <= bridge_m_eob_required;
                descriptor_last <= bridge_m_last;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accepted_pair_count <= '0;
            completed_pair_count <= '0;
            active_quality24 <= 1'b0;
        end else if (start_fire) begin
            accepted_pair_count <= '0;
            completed_pair_count <= '0;
            active_quality24 <= command_quality24;
        end else begin
            if (command_fire)
                accepted_pair_count <= accepted_pair_count + 1'b1;
            if (pair_done) begin
                if (completed_pair_count == 2) begin
                    accepted_pair_count <= '0;
                    completed_pair_count <= '0;
                end else begin
                    completed_pair_count <= completed_pair_count + 1'b1;
                end
            end
        end
    end

    custom_dct_quant_bank_bridge36 bridge (
        .clk(clk), .rst_n(rst_n), .clear_error(start_fire),
        .command_valid(command_valid && source_window_open
                       && (accepted_pair_count < 3)),
        .command_ready(bridge_command_ready),
        .command_quality24(active_quality24),
        .command_table_id(pair_table_id),
        .command_base_count(pair_base_count),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_row_a(s_row_a), .s_row_b(s_row_b),
        .m_valid(bridge_m_valid), .m_ready(bridge_m_ready),
        .m_op_type(bridge_m_op_type), .m_layer(bridge_m_layer),
        .m_mandatory(bridge_m_mandatory),
        .m_reserve_release(bridge_m_reserve_release),
        .m_table_class(bridge_m_table_class),
        .m_table_id(bridge_m_table_id), .m_symbol(bridge_m_symbol),
        .m_amplitude(bridge_m_amplitude),
        .m_amplitude_length(bridge_m_amplitude_length),
        .m_raw_value(bridge_m_raw_value),
        .m_raw_length(bridge_m_raw_length),
        .m_eob_required(bridge_m_eob_required), .m_last(bridge_m_last),
        .transform_done(transform_done), .block_done(block_done),
        .pair_done(pair_done), .busy(bridge_busy),
        .input_error(bridge_input_error), .saturated(bridge_saturated)
    );

    custom_descriptor_entropy_writer #(
        .COUNT_WIDTH(COUNT_WIDTH), .TOKEN_WIDTH(TOKEN_WIDTH),
        .BYTE_COUNT_WIDTH(BYTE_COUNT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) entropy (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .finish_valid(entropy_finish_valid), .finish_ready(finish_ready),
        .finish_done(finish_done),
        .prefix_valid(prefix_valid), .prefix_ready(prefix_ready),
        .prefix_mode(prefix_mode),
        .s_valid(descriptor_valid), .s_ready(entropy_s_ready),
        .s_op_type(descriptor_op_type), .s_layer(descriptor_layer),
        .s_mandatory(descriptor_mandatory),
        .s_reserve_release(descriptor_reserve_release),
        .s_table_class(descriptor_table_class),
        .s_table_id(descriptor_table_id), .s_symbol(descriptor_symbol),
        .s_amplitude(descriptor_amplitude),
        .s_amplitude_length(descriptor_amplitude_length),
        .s_raw_value(descriptor_raw_value),
        .s_raw_length(descriptor_raw_length),
        .s_eob_required(descriptor_eob_required),
        .source_block_done(descriptor_valid && entropy_s_ready
                           && descriptor_last),
        .source_busy(bridge_busy || descriptor_valid),
        .source_error(bridge_input_error),
        .source_saturated(bridge_saturated),
        .source_window_open(source_window_open),
        .m_valid(m_valid), .m_ready(m_ready), .m_layer(m_layer),
        .m_byte(m_byte), .drop_pulse(drop_pulse),
        .drop_layer(drop_layer), .fatal_error(fatal_error), .busy(busy),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count),
        .coefficient_saturated(coefficient_saturated),
        .token_fifo_level(unused_fifo_level)
    );

endmodule
