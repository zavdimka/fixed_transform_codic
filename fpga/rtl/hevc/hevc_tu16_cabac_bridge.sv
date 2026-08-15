module hevc_tu16_cabac_bridge (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_prediction,
    input  logic signed [8:0]  s_residual,
    input  logic [1:0]         s_quality,
    input  logic               s_luma_mode_dc,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_reconstructed,
    output logic [3:0]         m_x,
    output logic [3:0]         m_y,
    output logic               m_block_last,

    output logic               cu_valid,
    input  logic               cu_ready,
    output logic               cu_luma_mode_dc,
    output logic               cu_luma_cbf,

    output logic               coefficient_valid,
    input  logic               coefficient_ready,
    output logic [7:0]         coefficient_raster_address,
    output logic signed [15:0] coefficient,
    output logic               coefficient_block_last,

    output logic               block_done,
    output logic               block_error,
    output logic               busy
);
    logic block_owned;
    logic input_complete;
    logic [7:0] input_count;
    logic latched_mode_dc;
    logic any_nonzero;
    logic reconstruction_done;
    logic descriptor_pending;
    logic descriptor_cbf;

    logic replay_active;
    logic [7:0] replay_read_address;
    logic replay_output_valid;
    logic [7:0] replay_output_address;
    logic replay_output_last;

    logic loop_s_ready;
    logic loop_m_valid;
    logic loop_m_ready;
    logic [7:0] loop_m_reconstructed;
    logic [3:0] loop_m_x;
    logic [3:0] loop_m_y;
    logic loop_m_block_last;
    logic loop_m_block_error;
    logic loop_coefficient_write_enable;
    logic [7:0] loop_coefficient_write_address;
    logic signed [15:0] loop_coefficient_write_data;
    logic loop_coefficient_block_last;
    logic loop_block_busy;

    logic buffer_read_enable;
    logic [7:0] buffer_read_address;
    logic signed [15:0] buffer_read_data;

    wire source_fire = s_valid && s_ready;
    wire reconstructed_fire = m_valid && m_ready;
    wire reconstructed_last_fire = reconstructed_fire && m_block_last;
    wire descriptor_fire = cu_valid && cu_ready;
    wire coefficient_fire = coefficient_valid && coefficient_ready;
    wire coefficient_last_fire = coefficient_fire && coefficient_block_last;
    wire coefficient_nonzero = loop_coefficient_write_data != 0;
    wire coefficient_block_nonzero = any_nonzero || coefficient_nonzero;
    wire replay_can_read = replay_active &&
        (!replay_output_valid || coefficient_ready);
    wire descriptor_finished = !descriptor_pending || descriptor_fire;
    wire reconstruction_finished = reconstruction_done ||
        reconstructed_last_fire;
    wire replay_finished = !replay_active &&
        (!replay_output_valid || coefficient_last_fire);

    assign s_ready = loop_s_ready && (!block_owned || !input_complete);
    assign loop_m_ready = m_ready;
    assign m_valid = loop_m_valid;
    assign m_reconstructed = loop_m_reconstructed;
    assign m_x = loop_m_x;
    assign m_y = loop_m_y;
    assign m_block_last = loop_m_block_last;

    assign cu_valid = descriptor_pending;
    assign cu_luma_mode_dc = latched_mode_dc;
    assign cu_luma_cbf = descriptor_cbf;

    assign coefficient_valid = replay_output_valid;
    assign coefficient_raster_address = replay_output_address;
    assign coefficient = buffer_read_data;
    assign coefficient_block_last = replay_output_last;

    assign buffer_read_enable = replay_can_read;
    assign buffer_read_address = replay_read_address;
    assign busy = block_owned || loop_block_busy || descriptor_pending ||
        replay_active || replay_output_valid;

    hevc_tu16_reconstruction_loop reconstruction_loop (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid && s_ready),
        .s_ready(loop_s_ready),
        .s_prediction(s_prediction),
        .s_residual(s_residual),
        .s_quality(s_quality),
        .m_valid(loop_m_valid),
        .m_ready(loop_m_ready),
        .m_reconstructed(loop_m_reconstructed),
        .m_x(loop_m_x),
        .m_y(loop_m_y),
        .m_block_last(loop_m_block_last),
        .m_block_error(loop_m_block_error),
        .coefficient_write_enable(loop_coefficient_write_enable),
        .coefficient_write_address(loop_coefficient_write_address),
        .coefficient_write_data(loop_coefficient_write_data),
        .coefficient_block_last(loop_coefficient_block_last),
        .block_busy(loop_block_busy)
    );

    hevc_coefficient_buffer16 coefficient_buffer (
        .clk(clk),
        .write_enable(loop_coefficient_write_enable),
        .write_address(loop_coefficient_write_address),
        .write_data(loop_coefficient_write_data),
        .read_enable(buffer_read_enable),
        .read_address(buffer_read_address),
        .read_data(buffer_read_data)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_owned <= 1'b0;
            input_complete <= 1'b0;
            input_count <= 8'd0;
            latched_mode_dc <= 1'b0;
            any_nonzero <= 1'b0;
            reconstruction_done <= 1'b0;
            descriptor_pending <= 1'b0;
            descriptor_cbf <= 1'b0;
            replay_active <= 1'b0;
            replay_read_address <= 8'd0;
            replay_output_valid <= 1'b0;
            replay_output_address <= 8'd0;
            replay_output_last <= 1'b0;
            block_done <= 1'b0;
            block_error <= 1'b0;
        end else begin
            block_done <= 1'b0;

            if (source_fire) begin
                if (!block_owned) begin
                    block_owned <= 1'b1;
                    latched_mode_dc <= s_luma_mode_dc;
                    any_nonzero <= 1'b0;
                    reconstruction_done <= 1'b0;
                    block_error <= 1'b0;
                end
                if (input_count == 8'hff) begin
                    input_count <= 8'd0;
                    input_complete <= 1'b1;
                end else begin
                    input_count <= input_count + 1'b1;
                end
            end

            if (loop_coefficient_write_enable) begin
                any_nonzero <= coefficient_block_nonzero;
                if (loop_coefficient_block_last) begin
                    descriptor_pending <= 1'b1;
                    descriptor_cbf <= coefficient_block_nonzero;
                    if (coefficient_block_nonzero) begin
                        replay_active <= 1'b1;
                        replay_read_address <= 8'd0;
                    end
                end
            end

            if (descriptor_fire)
                descriptor_pending <= 1'b0;

            if (replay_output_valid && coefficient_ready)
                replay_output_valid <= 1'b0;
            if (replay_can_read) begin
                replay_output_valid <= 1'b1;
                replay_output_address <= replay_read_address;
                replay_output_last <= replay_read_address == 8'hff;
                if (replay_read_address == 8'hff) begin
                    replay_active <= 1'b0;
                end else begin
                    replay_read_address <= replay_read_address + 1'b1;
                end
            end

            if (reconstructed_last_fire) begin
                reconstruction_done <= 1'b1;
                if (loop_m_block_error)
                    block_error <= 1'b1;
            end

            if (block_owned && input_complete && descriptor_finished &&
                    reconstruction_finished && replay_finished) begin
                block_owned <= 1'b0;
                input_complete <= 1'b0;
                reconstruction_done <= 1'b0;
                any_nonzero <= 1'b0;
                block_done <= 1'b1;
            end
        end
    end
endmodule
