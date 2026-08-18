module custom_dct_quant_bank_bridge36 (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       clear_error,

    input  logic                       command_valid,
    output logic                       command_ready,
    input  logic                       command_quality24,
    input  logic                       command_table_id,
    input  logic [5:0]                 command_base_count,

    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic signed [127:0]        s_row_a,
    input  logic signed [127:0]        s_row_b,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [1:0]                 m_op_type,
    output logic                       m_layer,
    output logic                       m_mandatory,
    output logic [5:0]                 m_reserve_release,
    output logic                       m_table_class,
    output logic                       m_table_id,
    output logic [7:0]                 m_symbol,
    output logic [10:0]                m_amplitude,
    output logic [3:0]                 m_amplitude_length,
    output logic                       m_raw_value,
    output logic [1:0]                 m_raw_length,
    output logic                       m_eob_required,
    output logic                       m_last,

    output logic                       transform_done,
    output logic                       block_done,
    output logic                       pair_done,
    output logic                       busy,
    output logic                       input_error,
    output logic                       saturated
);
    logic dct_command_ready, queue_pair_ready;
    logic quant_m_valid, quant_m_ready;
    logic [5:0] quant_m_index;
    logic signed [11:0] quant_m_a0, quant_m_a1, quant_m_b0, quant_m_b1;
    logic quant_m_last, dct_busy, dct_input_error, dct_saturated;
    logic quant_pipe_valid;
    logic [5:0] quant_pipe_index;
    logic signed [11:0] quant_pipe_a0, quant_pipe_a1;
    logic signed [11:0] quant_pipe_b0, quant_pipe_b1;
    logic quant_pipe_last;
    logic queue_s_ready;
    logic queue_busy, queue_input_error, queue_saturated;
    logic command_metadata_valid;

    assign command_ready = dct_command_ready && queue_pair_ready;
    assign command_metadata_valid = command_base_count > 6'd1;
    assign busy = dct_busy || queue_busy;
    assign input_error = dct_input_error || queue_input_error;
    assign saturated = dct_saturated || queue_saturated;

    // Registered elastic boundary.  Quantization contains the reciprocal
    // correction and saturation logic, while the queue performs routing and
    // scan metadata updates.  Keeping the two in one combinational path costs
    // far more Fmax than this single cycle of latency.
    assign quant_m_ready = !quant_pipe_valid || queue_s_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quant_pipe_valid <= 1'b0;
        end else if (clear_error) begin
            quant_pipe_valid <= 1'b0;
        end else if (quant_m_ready) begin
            quant_pipe_valid <= quant_m_valid;
            if (quant_m_valid) begin
                quant_pipe_index <= quant_m_index;
                quant_pipe_a0 <= quant_m_a0;
                quant_pipe_a1 <= quant_m_a1;
                quant_pipe_b0 <= quant_m_b0;
                quant_pipe_b1 <= quant_m_b1;
                quant_pipe_last <= quant_m_last;
            end
        end
    end

    custom_dct_quant_pair36 dct_quant (
        .clk(clk), .rst_n(rst_n),
        .command_valid(command_valid && queue_pair_ready
                       && command_metadata_valid),
        .command_ready(dct_command_ready),
        .command_quality24(command_quality24),
        .command_table_id(command_table_id),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_row_a(s_row_a), .s_row_b(s_row_b),
        .m_valid(quant_m_valid), .m_ready(quant_m_ready),
        .m_index(quant_m_index),
        .m_a0(quant_m_a0), .m_a1(quant_m_a1),
        .m_b0(quant_m_b0), .m_b1(quant_m_b1),
        .m_last(quant_m_last), .done(transform_done),
        .busy(dct_busy), .input_error(dct_input_error),
        .saturated(dct_saturated)
    );

    custom_coefficient_pair_queue8 coefficient_queue (
        .clk(clk), .rst_n(rst_n), .clear_error(clear_error),
        .pair_valid(command_valid && dct_command_ready),
        .pair_ready(queue_pair_ready),
        .pair_table_id(command_table_id),
        .pair_base_count(command_base_count),
        .s_valid(quant_pipe_valid), .s_ready(queue_s_ready),
        .s_index(quant_pipe_index),
        .s_a0(quant_pipe_a0), .s_a1(quant_pipe_a1),
        .s_b0(quant_pipe_b0), .s_b1(quant_pipe_b1),
        .m_valid(m_valid), .m_ready(m_ready),
        .m_op_type(m_op_type), .m_layer(m_layer),
        .m_mandatory(m_mandatory),
        .m_reserve_release(m_reserve_release),
        .m_table_class(m_table_class), .m_table_id(m_table_id),
        .m_symbol(m_symbol), .m_amplitude(m_amplitude),
        .m_amplitude_length(m_amplitude_length),
        .m_raw_value(m_raw_value), .m_raw_length(m_raw_length),
        .m_eob_required(m_eob_required), .m_last(m_last),
        .block_done(block_done), .pair_done(pair_done),
        .busy(queue_busy), .coefficient_saturated(queue_saturated),
        .input_error(queue_input_error)
    );

    logic unused_quant_last;
    assign unused_quant_last = quant_pipe_last;
endmodule
