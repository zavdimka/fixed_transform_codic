module custom_dct_quant_pair36 (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       command_valid,
    output logic                       command_ready,
    input  logic                       command_quality24,
    input  logic                       command_table_id,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic signed [127:0]        s_row_a,
    input  logic signed [127:0]        s_row_b,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [5:0]                 m_index,
    output logic signed [11:0]         m_a0,
    output logic signed [11:0]         m_a1,
    output logic signed [11:0]         m_b0,
    output logic signed [11:0]         m_b1,
    output logic                       m_last,

    output logic                       done,
    output logic                       busy,
    output logic                       input_error,
    output logic                       saturated
);
    logic active_quality24, active_table_id;
    logic dct_command_ready, dct_m_valid, dct_m_ready;
    logic [5:0] dct_m_index;
    logic signed [15:0] dct_m_a0, dct_m_a1, dct_m_b0, dct_m_b1;
    logic dct_m_last, dct_done, dct_busy, dct_saturated;
    logic quant_s_ready, quant_busy, quant_input_error, quant_saturated;

    wire command_fire = command_valid && command_ready;
    wire output_fire = m_valid && m_ready;

    assign command_ready = dct_command_ready && !quant_busy;
    assign dct_m_ready = quant_s_ready;
    assign busy = dct_busy || quant_busy;
    assign input_error = quant_input_error;
    assign saturated = dct_saturated || quant_saturated;

    custom_dct8_pair32 dct (
        .clk(clk), .rst_n(rst_n),
        .command_valid(command_valid && !quant_busy),
        .command_ready(dct_command_ready),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_row_a(s_row_a), .s_row_b(s_row_b),
        .m_valid(dct_m_valid), .m_ready(dct_m_ready),
        .m_index(dct_m_index),
        .m_a0(dct_m_a0), .m_a1(dct_m_a1),
        .m_b0(dct_m_b0), .m_b1(dct_m_b1),
        .m_last(dct_m_last),
        .done(dct_done), .busy(dct_busy), .saturated(dct_saturated)
    );

    custom_quant_pair4 quantizer (
        .clk(clk), .rst_n(rst_n), .clear(command_fire),
        .s_valid(dct_m_valid), .s_ready(quant_s_ready),
        .s_quality24(active_quality24), .s_table_id(active_table_id),
        .s_index(dct_m_index),
        .s_a0(dct_m_a0), .s_a1(dct_m_a1),
        .s_b0(dct_m_b0), .s_b1(dct_m_b1),
        .m_valid(m_valid), .m_ready(m_ready), .m_index(m_index),
        .m_a0(m_a0), .m_a1(m_a1), .m_b0(m_b0), .m_b1(m_b1),
        .m_last(m_last), .busy(quant_busy),
        .input_error(quant_input_error), .saturated(quant_saturated)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_quality24 <= 1'b0;
            active_table_id <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (command_fire) begin
                active_quality24 <= command_quality24;
                active_table_id <= command_table_id;
            end
            if (output_fire && m_last)
                done <= 1'b1;
        end
    end

    logic unused_dct_status;
    assign unused_dct_status = dct_done ^ dct_m_last;
endmodule
