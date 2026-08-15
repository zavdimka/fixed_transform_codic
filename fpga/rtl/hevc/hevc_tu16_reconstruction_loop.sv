module hevc_tu16_reconstruction_loop (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_prediction,
    input  logic signed [8:0]  s_residual,
    input  logic [1:0]         s_quality,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_reconstructed,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last,
    output logic               m_block_error,

    output logic               coefficient_write_enable,
    output logic [7:0]         coefficient_write_address,
    output logic signed [15:0] coefficient_write_data,
    output logic               coefficient_block_last,
    output logic               block_busy
);
    typedef enum logic {
        LOAD_BLOCK,
        PROCESS_BLOCK
    } state_t;

    state_t state;
    logic [7:0] input_address;
    logic [1:0] latched_quality;
    logic block_error_latched;

    logic prediction_write_enable;
    logic prediction_read_enable;
    logic [7:0] prediction_read_address;
    logic [7:0] prediction_read_data;

    logic forward_ready;
    logic forward_valid;
    logic forward_output_ready;
    logic signed [15:0] forward_coefficient;
    logic [3:0] forward_x;
    logic [3:0] forward_y;
    logic forward_block_last;

    logic [5:0] profile_qp;
    logic [3:0] profile_qp_per;
    logic [2:0] profile_qp_rem;
    logic profile_valid;

    logic quant_ready;
    logic quant_valid;
    logic quant_output_ready;
    logic signed [15:0] quantized;
    logic signed [15:0] dequantized;
    logic quant_nonzero;
    logic quant_qp_error;
    logic [3:0] quant_x;
    logic [3:0] quant_y;
    logic quant_block_last;

    logic inverse_ready;
    logic inverse_valid;
    logic inverse_output_ready;
    logic signed [15:0] inverse_residual;
    logic [3:0] inverse_x;
    logic [3:0] inverse_y;
    logic inverse_block_last;

    logic pending_valid;
    logic pending_ready;
    logic signed [15:0] pending_residual;
    logic [3:0] pending_x;
    logic [3:0] pending_y;
    logic pending_block_last;

    logic reconstruct_ready;
    logic reconstruct_valid;
    logic [7:0] reconstruct_pixel;
    logic [3:0] reconstruct_x;
    logic [3:0] reconstruct_y;
    logic reconstruct_block_last;

    assign block_busy = state == PROCESS_BLOCK;
    assign s_ready = (state == LOAD_BLOCK) && forward_ready;
    assign prediction_write_enable = s_valid && s_ready;

    hevc_prediction_buffer16 prediction_buffer (
        .clk(clk),
        .write_enable(prediction_write_enable),
        .write_address(input_address),
        .write_data(s_prediction),
        .read_enable(prediction_read_enable),
        .read_address(prediction_read_address),
        .read_data(prediction_read_data)
    );

    hevc_forward_transform16 forward_transform (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid && (state == LOAD_BLOCK)),
        .s_ready(forward_ready),
        .s_residual(s_residual),
        .m_valid(forward_valid),
        .m_ready(forward_output_ready),
        .m_coefficient(forward_coefficient),
        .m_x(forward_x),
        .m_y(forward_y),
        .m_block_last(forward_block_last)
    );

    hevc_qp_profile qp_profile (
        .quality(latched_quality),
        .qp(profile_qp),
        .qp_per(profile_qp_per),
        .qp_rem(profile_qp_rem),
        .profile_valid(profile_valid)
    );

    assign forward_output_ready = quant_ready;

    hevc_quant_dequant16 quant_dequant (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(forward_valid),
        .s_ready(quant_ready),
        .s_coefficient(forward_coefficient),
        .s_qp_per(profile_qp_per),
        .s_qp_rem(profile_qp_rem),
        .s_x(forward_x),
        .s_y(forward_y),
        .s_block_last(forward_block_last),
        .m_valid(quant_valid),
        .m_ready(quant_output_ready),
        .m_quantized(quantized),
        .m_dequantized(dequantized),
        .m_nonzero(quant_nonzero),
        .m_qp_error(quant_qp_error),
        .m_x(quant_x),
        .m_y(quant_y),
        .m_block_last(quant_block_last)
    );

    assign quant_output_ready = inverse_ready;
    assign coefficient_write_enable = quant_valid && quant_output_ready;
    assign coefficient_write_address = {quant_y, quant_x};
    assign coefficient_write_data = quantized;
    assign coefficient_block_last = quant_block_last;

    hevc_inverse_transform16 inverse_transform (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(quant_valid),
        .s_ready(inverse_ready),
        .s_coefficient(dequantized),
        .m_valid(inverse_valid),
        .m_ready(inverse_output_ready),
        .m_residual(inverse_residual),
        .m_x(inverse_x),
        .m_y(inverse_y),
        .m_block_last(inverse_block_last)
    );

    assign pending_ready = !pending_valid || reconstruct_ready;
    assign inverse_output_ready = pending_ready;
    assign prediction_read_enable = inverse_valid && inverse_output_ready;
    assign prediction_read_address = {inverse_y, inverse_x};

    hevc_reconstruct #(
        .RESIDUAL_WIDTH(16)
    ) reconstruct (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(pending_valid),
        .s_ready(reconstruct_ready),
        .s_prediction(prediction_read_data),
        .s_residual(pending_residual),
        .m_valid(reconstruct_valid),
        .m_ready(m_ready),
        .m_reconstructed(reconstruct_pixel)
    );

    assign m_valid = reconstruct_valid;
    assign m_reconstructed = reconstruct_pixel;
    assign m_x = reconstruct_x;
    assign m_y = reconstruct_y;
    assign m_block_last = reconstruct_block_last;
    assign m_block_error = block_error_latched;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                  <= LOAD_BLOCK;
            input_address          <= '0;
            latched_quality        <= 2'd1;
            block_error_latched    <= 1'b0;
            pending_valid          <= 1'b0;
            pending_residual       <= '0;
            pending_x              <= '0;
            pending_y              <= '0;
            pending_block_last     <= 1'b0;
            reconstruct_x          <= '0;
            reconstruct_y          <= '0;
            reconstruct_block_last <= 1'b0;
        end else begin
            if (prediction_write_enable) begin
                if (input_address == 0) begin
                    latched_quality <= s_quality;
                    block_error_latched <= s_quality == 2'd3;
                end
                if (input_address == 255) begin
                    input_address <= '0;
                    state <= PROCESS_BLOCK;
                end else begin
                    input_address <= input_address + 1'b1;
                end
            end

            if (coefficient_write_enable && quant_qp_error) begin
                block_error_latched <= 1'b1;
            end

            if (pending_ready) begin
                pending_valid <= inverse_valid;
                if (inverse_valid) begin
                    pending_residual   <= inverse_residual;
                    pending_x          <= inverse_x;
                    pending_y          <= inverse_y;
                    pending_block_last <= inverse_block_last;
                end
            end

            if (pending_valid && reconstruct_ready) begin
                reconstruct_x          <= pending_x;
                reconstruct_y          <= pending_y;
                reconstruct_block_last <= pending_block_last;
            end

            if (m_valid && m_ready && m_block_last) begin
                state <= LOAD_BLOCK;
                input_address <= '0;
            end
        end
    end

    logic unused_profile_signals;
    assign unused_profile_signals = ^{profile_qp, profile_valid, quant_nonzero};
endmodule
