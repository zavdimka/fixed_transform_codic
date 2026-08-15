module hevc_shared_reconstruction_core (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               command_valid,
    output logic               command_ready,
    input  logic               command_size8,
    input  logic               command_chroma,
    input  logic [1:0]         command_quality,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_prediction,
    input  logic signed [8:0]  s_residual,

    output logic               coefficient_valid,
    input  logic               coefficient_ready,
    output logic signed [15:0] coefficient_data,
    output logic [3:0]         coefficient_x,
    output logic [3:0]         coefficient_y,
    output logic               coefficient_nonzero,
    output logic               coefficient_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_reconstructed,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last,
    output logic               m_block_error,

    output logic               done,
    output logic               busy
);
    typedef enum logic [2:0] {
        IDLE,
        FORWARD_COMMAND,
        LOAD_SOURCE,
        QUANTIZE,
        INVERSE_COMMAND,
        LOAD_DEQUANTIZED,
        RECONSTRUCT
    } state_t;

    state_t state;
    logic size8;
    logic chroma;
    logic [1:0] quality;
    logic [7:0] input_address;
    logic [7:0] replay_address;
    logic replay_issue_done;
    logic replay_valid;
    logic residual_valid;
    logic signed [15:0] residual_data;
    logic [3:0] residual_x;
    logic [3:0] residual_y;
    logic residual_last;
    logic block_error_latched;

    logic transform_command_valid;
    logic transform_command_ready;
    logic transform_s_valid;
    logic transform_s_ready;
    logic signed [15:0] transform_s_data;
    logic transform_m_valid;
    logic transform_m_ready;
    logic signed [15:0] transform_m_data;
    logic [3:0] transform_m_x;
    logic [3:0] transform_m_y;
    logic transform_m_last;
    logic transform_done;
    logic transform_error;
    logic transform_busy;

    logic quant_s_ready;
    logic quant_m_valid;
    logic quant_m_ready;
    logic signed [15:0] quantized;
    logic signed [15:0] dequantized;
    logic quant_nonzero;
    logic quant_qp_error;
    logic [3:0] quant_x;
    logic [3:0] quant_y;
    logic quant_last;

    logic [5:0] luma_qp;
    logic [3:0] luma_qp_per;
    logic [2:0] luma_qp_rem;
    logic profile_valid;
    logic [5:0] chroma_qp;
    logic [3:0] chroma_qp_per;
    logic [2:0] chroma_qp_rem;
    logic chroma_qp_error;
    logic [3:0] selected_qp_per;
    logic [2:0] selected_qp_rem;

    logic prediction_write_enable;
    logic prediction_read_enable;
    logic [7:0] prediction_read_address;
    logic [7:0] prediction_read_data;
    logic dequant_write_enable;
    logic [7:0] dequant_write_address;
    logic dequant_read_enable;
    logic signed [15:0] dequant_read_data;

    logic reconstruct_s_ready;
    logic reconstruct_m_valid;
    logic [7:0] reconstruct_pixel;

    wire command_fire = command_valid && command_ready;
    wire source_fire = s_valid && s_ready;
    wire coefficient_fire = coefficient_valid && coefficient_ready;
    wire replay_fire = transform_s_valid && transform_s_ready;
    // The synchronous EBR read port and replay_valid form a one-entry
    // elastic stage; an accepted value and the next read may share a clock.
    wire replay_output_ready = !replay_valid || transform_s_ready;
    wire replay_issue = (state == LOAD_DEQUANTIZED) &&
                        !replay_issue_done && replay_output_ready;
    // prediction_read_data and residual metadata form the elastic stage
    // between the synchronous prediction EBR and reconstruct output register.
    wire prediction_stage_ready = !residual_valid || reconstruct_s_ready;
    wire transform_output_fire = transform_m_valid && transform_m_ready;
    wire reconstruct_input_fire = residual_valid && reconstruct_s_ready;
    wire output_fire = m_valid && m_ready;
    wire [7:0] final_address = size8 ? 8'd63 : 8'd255;

    function automatic logic [7:0] raster_address(
        input logic block_size8,
        input logic [3:0] x,
        input logic [3:0] y
    );
        if (block_size8)
            raster_address = {2'b00, y[2:0], x[2:0]};
        else
            raster_address = {y, x};
    endfunction

    assign command_ready = state == IDLE;
    assign busy = state != IDLE;
    assign s_ready = (state == LOAD_SOURCE) && transform_s_ready;
    assign prediction_write_enable = source_fire;

    assign transform_command_valid = (state == FORWARD_COMMAND) ||
                                     (state == INVERSE_COMMAND);
    assign transform_s_valid = (state == LOAD_SOURCE) ? s_valid :
                               ((state == LOAD_DEQUANTIZED) && replay_valid);
    assign transform_s_data = (state == LOAD_SOURCE)
        ? {{7{s_residual[8]}}, s_residual} : dequant_read_data;
    assign transform_m_ready = (state == QUANTIZE) ? quant_s_ready :
        ((state == RECONSTRUCT) && prediction_stage_ready);

    /* verilator lint_off PINMISSING */
    hevc_shared_transform_core transform (
        .clk, .rst_n,
        .command_valid(transform_command_valid),
        .command_ready(transform_command_ready),
        .command_size8(size8),
        .command_inverse(state == INVERSE_COMMAND),
        .s_valid(transform_s_valid), .s_ready(transform_s_ready),
        .s_data(transform_s_data),
        .m_valid(transform_m_valid), .m_ready(transform_m_ready),
        .m_data(transform_m_data), .m_x(transform_m_x), .m_y(transform_m_y),
        .m_block_last(transform_m_last), .done(transform_done),
        .protocol_error(transform_error), .busy(transform_busy)
    );
    /* verilator lint_on PINMISSING */

    hevc_qp_profile profile (
        .quality, .qp(luma_qp), .qp_per(luma_qp_per),
        .qp_rem(luma_qp_rem), .profile_valid
    );

    hevc_chroma_qp chroma_map (
        .luma_qp, .chroma_qp, .qp_per(chroma_qp_per),
        .qp_rem(chroma_qp_rem), .qp_error(chroma_qp_error)
    );

    always_comb begin
        selected_qp_per = luma_qp_per;
        selected_qp_rem = luma_qp_rem;
        if (chroma) begin
            selected_qp_per = chroma_qp_per;
            selected_qp_rem = chroma_qp_rem;
        end
    end

    hevc_shared_quant_dequant quant (
        .clk, .rst_n,
        .s_valid((state == QUANTIZE) && transform_m_valid),
        .s_ready(quant_s_ready), .s_size8(size8),
        .s_coefficient(transform_m_data),
        .s_qp_per(selected_qp_per), .s_qp_rem(selected_qp_rem),
        .s_x(transform_m_x), .s_y(transform_m_y),
        .s_block_last(transform_m_last),
        .m_valid(quant_m_valid), .m_ready(quant_m_ready),
        .m_quantized(quantized), .m_dequantized(dequantized),
        .m_nonzero(quant_nonzero), .m_qp_error(quant_qp_error),
        .m_x(quant_x), .m_y(quant_y), .m_block_last(quant_last)
    );

    assign coefficient_valid = (state == QUANTIZE) && quant_m_valid;
    assign quant_m_ready = (state == QUANTIZE) && coefficient_ready;
    assign coefficient_data = quantized;
    assign coefficient_x = quant_x;
    assign coefficient_y = quant_y;
    assign coefficient_nonzero = quant_nonzero;
    assign coefficient_block_last = quant_last;
    assign dequant_write_enable = coefficient_fire;
    assign dequant_write_address = raster_address(size8, quant_x, quant_y);

    hevc_prediction_buffer16 prediction_buffer (
        .clk, .write_enable(prediction_write_enable),
        .write_address(input_address), .write_data(s_prediction),
        .read_enable(prediction_read_enable),
        .read_address(prediction_read_address),
        .read_data(prediction_read_data)
    );

    hevc_coefficient_buffer16 dequantized_buffer (
        .clk, .write_enable(dequant_write_enable),
        .write_address(dequant_write_address), .write_data(dequantized),
        .read_enable(dequant_read_enable), .read_address(replay_address),
        .read_data(dequant_read_data)
    );

    assign dequant_read_enable = replay_issue;
    assign prediction_read_enable = (state == RECONSTRUCT) &&
                                    transform_output_fire;
    assign prediction_read_address = raster_address(
        size8, transform_m_x, transform_m_y);

    hevc_reconstruct #(.RESIDUAL_WIDTH(16)) reconstruct (
        .clk, .rst_n, .s_valid(residual_valid),
        .s_ready(reconstruct_s_ready),
        .s_prediction(prediction_read_data), .s_residual(residual_data),
        .m_valid(reconstruct_m_valid), .m_ready,
        .m_reconstructed(reconstruct_pixel)
    );

    assign m_valid = reconstruct_m_valid;
    assign m_reconstructed = reconstruct_pixel;
    assign m_block_error = block_error_latched;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            size8 <= 1'b0;
            chroma <= 1'b0;
            quality <= 2'd1;
            input_address <= '0;
            replay_address <= '0;
            replay_issue_done <= 1'b0;
            replay_valid <= 1'b0;
            residual_valid <= 1'b0;
            residual_data <= '0;
            residual_x <= '0;
            residual_y <= '0;
            residual_last <= 1'b0;
            block_error_latched <= 1'b0;
            m_x <= '0;
            m_y <= '0;
            m_block_last <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (command_fire) begin
                size8 <= command_size8;
                chroma <= command_chroma;
                quality <= command_quality;
                input_address <= '0;
                block_error_latched <= command_quality == 2'd3;
                state <= FORWARD_COMMAND;
            end

            if ((state == FORWARD_COMMAND) && transform_command_ready)
                state <= LOAD_SOURCE;

            if (source_fire) begin
                if (input_address == final_address) begin
                    input_address <= '0;
                    state <= QUANTIZE;
                end else begin
                    input_address <= input_address + 1'b1;
                end
            end

            if (coefficient_fire) begin
                if (quant_qp_error || !profile_valid ||
                        (chroma && chroma_qp_error))
                    block_error_latched <= 1'b1;
                if (quant_last) begin
                    replay_address <= '0;
                    replay_issue_done <= 1'b0;
                    replay_valid <= 1'b0;
                    state <= INVERSE_COMMAND;
                end
            end

            if ((state == INVERSE_COMMAND) && transform_command_ready)
                state <= LOAD_DEQUANTIZED;

            if ((state == LOAD_DEQUANTIZED) && replay_output_ready) begin
                replay_valid <= replay_issue;
                if (replay_issue) begin
                    if (replay_address == final_address)
                        replay_issue_done <= 1'b1;
                    else
                        replay_address <= replay_address + 1'b1;
                end
            end
            if (replay_fire && (state == LOAD_DEQUANTIZED) &&
                    replay_issue_done) begin
                replay_address <= '0;
                residual_valid <= 1'b0;
                state <= RECONSTRUCT;
            end

            if ((state == RECONSTRUCT) && prediction_stage_ready) begin
                residual_valid <= transform_output_fire;
                if (transform_output_fire) begin
                    residual_data <= transform_m_data;
                    residual_x <= transform_m_x;
                    residual_y <= transform_m_y;
                    residual_last <= transform_m_last;
                end
            end
            if (reconstruct_input_fire) begin
                m_x <= residual_x;
                m_y <= residual_y;
                m_block_last <= residual_last;
            end

            if (output_fire && m_block_last) begin
                state <= IDLE;
                input_address <= '0;
                replay_address <= '0;
                done <= 1'b1;
            end
        end
    end

    logic unused_transform_status;
    assign unused_transform_status = ^{transform_done, transform_error,
        transform_busy, chroma_qp};
endmodule
