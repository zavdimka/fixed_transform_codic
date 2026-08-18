module custom_block_entropy_writer8 #(
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

    input  logic                          block_valid,
    output logic                          block_ready,
    input  logic                          block_table_id,
    input  logic [5:0]                    block_base_count,
    input  logic                          coefficient_valid,
    output logic                          coefficient_ready,
    input  logic signed [11:0]            coefficient,
    output logic                          block_done,

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
    output logic                          coefficient_saturated
);

    localparam integer FIFO_LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);

    logic writer_start_ready, writer_finish_ready, writer_busy;
    logic scanner_block_ready, scanner_m_valid, scanner_m_ready;
    logic scanner_busy, scanner_input_error;
    logic [1:0] scanner_m_op_type;
    logic scanner_m_layer, scanner_m_mandatory, scanner_m_table_class;
    logic scanner_m_table_id, scanner_m_raw_value, scanner_m_eob_required;
    logic [5:0] scanner_m_reserve_release;
    logic [7:0] scanner_m_symbol;
    logic [10:0] scanner_m_amplitude;
    logic [3:0] scanner_m_amplitude_length;
    logic [1:0] scanner_m_raw_length;

    logic token_m_valid, token_m_ready, token_m_layer, token_m_mandatory;
    logic [TOKEN_WIDTH-1:0] token_m_bits;
    logic [5:0] token_m_length;
    logic [COUNT_WIDTH-1:0] token_m_reserve_release;
    logic token_input_error, token_busy;
    logic [FIFO_LEVEL_WIDTH-1:0] token_fifo_level;
    logic start_fire, writer_fatal_error, scanner_error_latched;

    assign start_ready = writer_start_ready && !scanner_busy && !token_busy;
    assign start_fire = start_valid && start_ready;
    assign block_ready = writer_busy && !finish_valid && scanner_block_ready;
    assign finish_ready = writer_finish_ready && !scanner_busy && !token_busy;
    assign busy = writer_busy || scanner_busy || token_busy
                || (token_fifo_level != 0);
    assign fatal_error = scanner_input_error || scanner_error_latched
                       || token_input_error
                       || writer_fatal_error;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scanner_error_latched <= 1'b0;
        else if (start_fire)
            scanner_error_latched <= 1'b0;
        else if (scanner_input_error)
            scanner_error_latched <= 1'b1;
    end

    custom_coefficient_pingpong8 scanner (
        .clk(clk),
        .rst_n(rst_n),
        .clear_error(start_fire),
        .block_valid(block_valid && writer_busy && !finish_valid),
        .block_ready(scanner_block_ready),
        .block_table_id(block_table_id),
        .block_base_count(block_base_count),
        .s_valid(coefficient_valid),
        .s_ready(coefficient_ready),
        .s_coefficient(coefficient),
        .m_valid(scanner_m_valid),
        .m_ready(scanner_m_ready),
        .m_op_type(scanner_m_op_type),
        .m_layer(scanner_m_layer),
        .m_mandatory(scanner_m_mandatory),
        .m_reserve_release(scanner_m_reserve_release),
        .m_table_class(scanner_m_table_class),
        .m_table_id(scanner_m_table_id),
        .m_symbol(scanner_m_symbol),
        .m_amplitude(scanner_m_amplitude),
        .m_amplitude_length(scanner_m_amplitude_length),
        .m_raw_value(scanner_m_raw_value),
        .m_raw_length(scanner_m_raw_length),
        .m_eob_required(scanner_m_eob_required),
        // The wrapper uses block_done; the operation-level marker is not
        // needed after the ordered two-bank scheduler.
        /* verilator lint_off PINCONNECTEMPTY */
        .m_last(),
        /* verilator lint_on PINCONNECTEMPTY */
        .block_done(block_done),
        .busy(scanner_busy),
        .coefficient_saturated(coefficient_saturated),
        .input_error(scanner_input_error)
    );

    custom_syntax_token_buffer #(
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .COUNT_WIDTH(COUNT_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) syntax_tokens (
        .clk(clk),
        .rst_n(rst_n),
        .clear(start_fire),
        .s_valid(scanner_m_valid),
        .s_ready(scanner_m_ready),
        .s_op_type(scanner_m_op_type),
        .s_layer(scanner_m_layer),
        .s_mandatory(scanner_m_mandatory),
        .s_reserve_release(scanner_m_reserve_release),
        .s_table_class(scanner_m_table_class),
        .s_table_id(scanner_m_table_id),
        .s_symbol(scanner_m_symbol),
        .s_amplitude(scanner_m_amplitude),
        .s_amplitude_length(scanner_m_amplitude_length),
        .s_raw_value(scanner_m_raw_value),
        .s_raw_length(scanner_m_raw_length),
        .s_eob_required(scanner_m_eob_required),
        .m_valid(token_m_valid),
        .m_ready(token_m_ready),
        .m_layer(token_m_layer),
        .m_bits(token_m_bits),
        .m_length(token_m_length),
        .m_mandatory(token_m_mandatory),
        .m_reserve_release(token_m_reserve_release),
        .input_error(token_input_error),
        .busy(token_busy),
        .fifo_level(token_fifo_level)
    );

    custom_bounded_byte_writer #(
        .COUNT_WIDTH(COUNT_WIDTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .BYTE_COUNT_WIDTH(BYTE_COUNT_WIDTH)
    ) writer (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(start_fire),
        .start_ready(writer_start_ready),
        .base_limit_bits(base_limit_bits),
        .enhancement_limit_bits(enhancement_limit_bits),
        .base_reserved_bits(base_reserved_bits),
        .enhancement_reserved_bits(enhancement_reserved_bits),
        .finish_valid(finish_valid && !scanner_busy && !token_busy),
        .finish_ready(writer_finish_ready),
        .finish_done(finish_done),
        .s_valid(token_m_valid),
        .s_ready(token_m_ready),
        .s_layer(token_m_layer),
        .s_bits(token_m_bits),
        .s_length(token_m_length),
        .s_mandatory(token_m_mandatory),
        .s_reserve_release(token_m_reserve_release),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_layer(m_layer),
        .m_byte(m_byte),
        .drop_pulse(drop_pulse),
        .drop_layer(drop_layer),
        .fatal_error(writer_fatal_error),
        .busy(writer_busy),
        .base_used_bits(base_used_bits),
        .enhancement_used_bits(enhancement_used_bits),
        .base_byte_count(base_byte_count),
        .enhancement_byte_count(enhancement_byte_count)
    );

endmodule
