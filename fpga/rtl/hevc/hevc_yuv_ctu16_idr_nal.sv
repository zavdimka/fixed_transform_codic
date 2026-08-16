module hevc_yuv_ctu16_idr_nal #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 768,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16,
    parameter integer CTU_ROWS = FRAME_HEIGHT / 16,
    parameter integer SLICE_CTU_ROWS = 4,
    parameter logic [5:0] NAL_UNIT_TYPE = 6'd20
) (
    input logic clk, input logic rst_n,
    input logic start_valid, output logic start_ready,
    input logic [5:0] slice_row, input logic [5:0] qp,
    input logic no_output_of_prior_pics,
    input logic ctu_start_valid, output logic ctu_start_ready,

    input logic y_valid, output logic y_ready,
    input logic [7:0] y_prediction,
    input logic signed [8:0] y_residual,
    input logic [1:0] quality, input logic y_luma_mode_dc,
    input logic cb_valid, output logic cb_ready, input logic [7:0] cb_pixel,
    input logic cr_valid, output logic cr_ready, input logic [7:0] cr_pixel,

    output logic y_recon_valid, input logic y_recon_ready,
    output logic [7:0] y_reconstructed,
    output logic [3:0] y_recon_x, output logic [3:0] y_recon_y,
    output logic y_recon_block_last,
    output logic chroma_recon_valid, input logic chroma_recon_ready,
    output logic [1:0] chroma_recon_plane,
    output logic [7:0] chroma_reconstructed,
    output logic [2:0] chroma_recon_x, output logic [2:0] chroma_recon_y,
    output logic chroma_recon_block_last,

    output logic nal_valid, input logic nal_ready,
    output logic [7:0] nal_byte, output logic nal_last,
    output logic [6:0] current_ctu_x, output logic [5:0] current_ctu_y,
    output logic current_luma_mode_dc,
    output logic luma_tu_done, output logic chroma_tu_done,
    output logic ctu_done, output logic done,
    output logic parameter_error, output logic protocol_error,
    output logic busy
);
    logic ctu_active;
    logic [5:0] slice_base_y;
    logic luma_descriptor_captured, chroma_descriptor_captured;
    logic combined_descriptor_sent;
    logic luma_mode_register, luma_cbf_register;
    logic cb_cbf_register, cr_cbf_register;
    logic luma_done_seen, chroma_done_seen, nal_ctu_done_seen, nal_done_seen;

    logic reconstruction_start_ready, reconstruction_busy;
    logic reconstruction_block_error, reconstruction_protocol_error;
    logic reconstruction_parameter_error;
    logic luma_s_ready, luma_cu_valid, luma_cu_ready;
    logic luma_cu_mode_dc, luma_cu_cbf;
    logic luma_coefficient_valid;
    logic [7:0] luma_coefficient_address;
    logic signed [15:0] luma_coefficient;
    logic luma_coefficient_last, luma_bridge_done;
    logic chroma_descriptor_valid, chroma_descriptor_ready;
    logic chroma_cb_cbf, chroma_cr_cbf, chroma_block_done;
    logic cb_coefficient_valid, cr_coefficient_valid;
    logic [5:0] cb_coefficient_address, cr_coefficient_address;
    logic signed [15:0] cb_coefficient, cr_coefficient;
    logic cb_coefficient_last, cr_coefficient_last;

    logic nal_ctu_start_ready, nal_cu_ready;
    logic nal_y_ready, nal_cb_ready, nal_cr_ready;
    logic nal_y_done, nal_cb_done, nal_cr_done;
    logic nal_ctu_done, nal_done, nal_parameter_error, nal_protocol_error;
    logic nal_busy;

    wire start_fire = start_valid && start_ready;
    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;
    wire luma_descriptor_fire = luma_cu_valid && luma_cu_ready;
    wire chroma_descriptor_fire = chroma_descriptor_valid &&
        chroma_descriptor_ready;
    wire combined_descriptor_valid = luma_descriptor_captured &&
        chroma_descriptor_captured && !combined_descriptor_sent;
    wire combined_descriptor_fire = combined_descriptor_valid && nal_cu_ready;
    wire top_available = current_ctu_y != slice_base_y;
    wire joined_ctu_done = ctu_active &&
        (luma_done_seen || luma_bridge_done) &&
        (chroma_done_seen || chroma_block_done) &&
        (nal_ctu_done_seen || nal_ctu_done);

    assign ctu_start_ready = !ctu_active && nal_ctu_start_ready &&
        reconstruction_start_ready;
    assign y_ready = ctu_active && luma_s_ready;
    assign luma_cu_ready = ctu_active && !luma_descriptor_captured;
    assign chroma_descriptor_ready = ctu_active &&
        !chroma_descriptor_captured;
    assign current_luma_mode_dc = luma_mode_register;
    assign parameter_error = nal_parameter_error ||
        reconstruction_parameter_error;
    assign protocol_error = nal_protocol_error || reconstruction_protocol_error ||
        reconstruction_block_error;
    assign busy = ctu_active || reconstruction_busy || nal_busy;

    hevc_yuv_dual_reconstruction_bridge #(
        .FRAME_WIDTH(FRAME_WIDTH), .CTU_COLUMNS(CTU_COLUMNS)
    ) reconstruction (
        .clk, .rst_n, .start_valid(ctu_start_fire),
        .start_ready(reconstruction_start_ready), .ctu_x(current_ctu_x),
        .top_available(top_available), .quality(quality),
        .y_valid(y_valid && ctu_active), .y_ready(luma_s_ready),
        .y_prediction(y_prediction), .y_residual(y_residual),
        .y_luma_mode_dc(y_luma_mode_dc),
        .cb_valid(cb_valid), .cb_ready(cb_ready), .cb_pixel(cb_pixel),
        .cr_valid(cr_valid), .cr_ready(cr_ready), .cr_pixel(cr_pixel),
        .y_recon_valid(y_recon_valid), .y_recon_ready(y_recon_ready),
        .y_reconstructed(y_reconstructed), .y_recon_x(y_recon_x),
        .y_recon_y(y_recon_y), .y_recon_block_last(y_recon_block_last),
        .chroma_recon_valid(chroma_recon_valid),
        .chroma_recon_ready(chroma_recon_ready),
        .chroma_recon_plane(chroma_recon_plane),
        .chroma_reconstructed(chroma_reconstructed),
        .chroma_recon_x(chroma_recon_x), .chroma_recon_y(chroma_recon_y),
        .chroma_recon_block_last(chroma_recon_block_last),
        .luma_cu_valid(luma_cu_valid), .luma_cu_ready(luma_cu_ready),
        .luma_cu_mode_dc(luma_cu_mode_dc), .luma_cu_cbf(luma_cu_cbf),
        .chroma_descriptor_valid(chroma_descriptor_valid),
        .chroma_descriptor_ready(chroma_descriptor_ready),
        .cb_cbf(chroma_cb_cbf), .cr_cbf(chroma_cr_cbf),
        .y_coefficient_valid(luma_coefficient_valid),
        .y_coefficient_ready(nal_y_ready),
        .y_coefficient_address(luma_coefficient_address),
        .y_coefficient(luma_coefficient),
        .y_coefficient_last(luma_coefficient_last),
        .cb_coefficient_valid(cb_coefficient_valid),
        .cb_coefficient_ready(nal_cb_ready),
        .cb_coefficient_address(cb_coefficient_address),
        .cb_coefficient(cb_coefficient),
        .cb_coefficient_last(cb_coefficient_last),
        .cr_coefficient_valid(cr_coefficient_valid),
        .cr_coefficient_ready(nal_cr_ready),
        .cr_coefficient_address(cr_coefficient_address),
        .cr_coefficient(cr_coefficient),
        .cr_coefficient_last(cr_coefficient_last),
        .luma_block_done(luma_bridge_done),
        .chroma_block_done(chroma_block_done),
        .block_error(reconstruction_block_error),
        .protocol_error(reconstruction_protocol_error),
        .parameter_error(reconstruction_parameter_error),
        .busy(reconstruction_busy));

    hevc_idr_ctu16_yuv_nal #(
        .CTU_COLUMNS(CTU_COLUMNS), .CTU_ROWS(CTU_ROWS),
        .SLICE_CTU_ROWS(SLICE_CTU_ROWS), .NAL_UNIT_TYPE(NAL_UNIT_TYPE)
    ) idr_nal (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid),
        .start_ready(start_ready), .slice_row(slice_row), .qp(qp),
        .no_output_of_prior_pics(no_output_of_prior_pics),
        .ctu_start_valid(ctu_start_fire),
        .ctu_start_ready(nal_ctu_start_ready),
        .cu_valid(combined_descriptor_valid), .cu_ready(nal_cu_ready),
        .cu_luma_mode_dc(luma_mode_register),
        .cu_luma_cbf(luma_cbf_register), .cu_cb_cbf(cb_cbf_register),
        .cu_cr_cbf(cr_cbf_register),
        .y_valid(luma_coefficient_valid), .y_ready(nal_y_ready),
        .y_raster_address(luma_coefficient_address),
        .y_coefficient(luma_coefficient), .y_block_last(luma_coefficient_last),
        .cb_valid(cb_coefficient_valid), .cb_ready(nal_cb_ready),
        .cb_raster_address(cb_coefficient_address),
        .cb_coefficient(cb_coefficient), .cb_block_last(cb_coefficient_last),
        .cr_valid(cr_coefficient_valid), .cr_ready(nal_cr_ready),
        .cr_raster_address(cr_coefficient_address),
        .cr_coefficient(cr_coefficient), .cr_block_last(cr_coefficient_last),
        .m_valid(nal_valid), .m_ready(nal_ready), .m_byte(nal_byte),
        .m_last(nal_last), .current_ctu_x(current_ctu_x),
        .current_ctu_y(current_ctu_y), .y_block_done(nal_y_done),
        .cb_block_done(nal_cb_done), .cr_block_done(nal_cr_done),
        .ctu_done(nal_ctu_done), .done(nal_done),
        .parameter_error(nal_parameter_error),
        .protocol_error(nal_protocol_error), .busy(nal_busy));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ctu_active <= 1'b0;
            slice_base_y <= 6'd0; luma_descriptor_captured <= 1'b0;
            chroma_descriptor_captured <= 1'b0;
            combined_descriptor_sent <= 1'b0;
            luma_mode_register <= 1'b1; luma_cbf_register <= 1'b0;
            cb_cbf_register <= 1'b0; cr_cbf_register <= 1'b0;
            luma_done_seen <= 1'b0; chroma_done_seen <= 1'b0;
            nal_ctu_done_seen <= 1'b0; nal_done_seen <= 1'b0;
            luma_tu_done <= 1'b0; chroma_tu_done <= 1'b0;
            ctu_done <= 1'b0; done <= 1'b0;
        end else begin
            luma_tu_done <= luma_bridge_done;
            chroma_tu_done <= chroma_block_done;
            ctu_done <= 1'b0; done <= 1'b0;
            if (start_fire)
                slice_base_y <= 6'(slice_row * SLICE_CTU_ROWS);
            if (luma_bridge_done) luma_done_seen <= 1'b1;
            if (chroma_block_done) chroma_done_seen <= 1'b1;
            if (nal_ctu_done) nal_ctu_done_seen <= 1'b1;
            if (nal_done) nal_done_seen <= 1'b1;
            if (ctu_start_fire) begin
                ctu_active <= 1'b1;
                luma_descriptor_captured <= 1'b0;
                chroma_descriptor_captured <= 1'b0;
                combined_descriptor_sent <= 1'b0;
                luma_done_seen <= 1'b0; chroma_done_seen <= 1'b0;
                nal_ctu_done_seen <= 1'b0;
            end
            if (luma_descriptor_fire) begin
                luma_descriptor_captured <= 1'b1;
                luma_mode_register <= luma_cu_mode_dc;
                luma_cbf_register <= luma_cu_cbf;
            end
            if (chroma_descriptor_fire) begin
                chroma_descriptor_captured <= 1'b1;
                cb_cbf_register <= chroma_cb_cbf;
                cr_cbf_register <= chroma_cr_cbf;
            end
            if (combined_descriptor_fire)
                combined_descriptor_sent <= 1'b1;
            if (joined_ctu_done) begin
                ctu_active <= 1'b0; ctu_done <= 1'b1;
                luma_done_seen <= 1'b0; chroma_done_seen <= 1'b0;
                nal_ctu_done_seen <= 1'b0;
                if (nal_done_seen || nal_done) begin
                    done <= 1'b1; nal_done_seen <= 1'b0;
                end
            end else if (nal_done && !ctu_active && !reconstruction_busy) begin
                done <= 1'b1; nal_done_seen <= 1'b0;
            end
        end
    end

    logic unused_syntax_done;
    assign unused_syntax_done = ^{nal_y_done, nal_cb_done, nal_cr_done};
endmodule
