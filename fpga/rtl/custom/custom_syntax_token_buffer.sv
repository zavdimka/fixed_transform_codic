module custom_syntax_token_buffer #(
    parameter integer TOKEN_WIDTH = 32,
    parameter integer COUNT_WIDTH = 17,
    parameter integer FIFO_DEPTH = 4,
    parameter integer FIFO_LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1)
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [1:0]                 s_op_type,
    input  logic                       s_layer,
    input  logic                       s_mandatory,
    input  logic [5:0]                 s_reserve_release,
    input  logic                       s_table_class,
    input  logic                       s_table_id,
    input  logic [7:0]                 s_symbol,
    input  logic [10:0]                s_amplitude,
    input  logic [3:0]                 s_amplitude_length,
    input  logic                       s_raw_value,
    input  logic [1:0]                 s_raw_length,
    input  logic                       s_eob_required,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic                       m_layer,
    output logic [TOKEN_WIDTH-1:0]     m_bits,
    output logic [5:0]                 m_length,
    output logic                       m_mandatory,
    output logic [COUNT_WIDTH-1:0]     m_reserve_release,

    output logic                       input_error,
    output logic                       busy,
    output logic [FIFO_LEVEL_WIDTH-1:0] fifo_level
);

    logic dispatcher_m_valid, dispatcher_m_ready;
    logic dispatcher_m_layer, dispatcher_m_mandatory;
    logic [TOKEN_WIDTH-1:0] dispatcher_m_bits;
    logic [5:0] dispatcher_m_length, dispatcher_m_reserve_release;
    logic [5:0] fifo_reserve_release;
    logic dispatcher_busy;

    custom_syntax_dispatcher #(
        .TOKEN_WIDTH(TOKEN_WIDTH)
    ) dispatcher (
        .clk(clk),
        .rst_n(rst_n),
        .clear_error(clear),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_op_type(s_op_type),
        .s_layer(s_layer),
        .s_mandatory(s_mandatory),
        .s_reserve_release(s_reserve_release),
        .s_table_class(s_table_class),
        .s_table_id(s_table_id),
        .s_symbol(s_symbol),
        .s_amplitude(s_amplitude),
        .s_amplitude_length(s_amplitude_length),
        .s_raw_value(s_raw_value),
        .s_raw_length(s_raw_length),
        .s_eob_required(s_eob_required),
        .m_valid(dispatcher_m_valid),
        .m_ready(dispatcher_m_ready),
        .m_layer(dispatcher_m_layer),
        .m_bits(dispatcher_m_bits),
        .m_length(dispatcher_m_length),
        .m_mandatory(dispatcher_m_mandatory),
        .m_reserve_release(dispatcher_m_reserve_release),
        .input_error(input_error),
        .busy(dispatcher_busy)
    );

    custom_budget_token_fifo #(
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .COUNT_WIDTH(6),
        .DEPTH(FIFO_DEPTH)
    ) fifo (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .s_valid(dispatcher_m_valid),
        .s_ready(dispatcher_m_ready),
        .s_layer(dispatcher_m_layer),
        .s_bits(dispatcher_m_bits),
        .s_length(dispatcher_m_length),
        .s_mandatory(dispatcher_m_mandatory),
        .s_reserve_release(dispatcher_m_reserve_release),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_layer(m_layer),
        .m_bits(m_bits),
        .m_length(m_length),
        .m_mandatory(m_mandatory),
        .m_reserve_release(fifo_reserve_release),
        .level(fifo_level)
    );

    assign m_reserve_release =
        {{(COUNT_WIDTH-6){1'b0}}, fifo_reserve_release};
    assign busy = dispatcher_busy || (fifo_level != 0);

endmodule
