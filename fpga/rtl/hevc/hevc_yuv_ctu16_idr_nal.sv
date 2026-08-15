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
    logic [1:0] quality_register;
    logic [5:0] slice_base_y;
    logic luma_descriptor_captured, chroma_descriptor_captured;
    logic combined_descriptor_sent;
    logic luma_mode_register, luma_cbf_register;
    logic cb_cbf_register, cr_cbf_register;
    logic luma_done_seen, chroma_done_seen, nal_ctu_done_seen, nal_done_seen;

    logic luma_s_ready, luma_cu_valid, luma_cu_ready;
    logic luma_cu_mode_dc, luma_cu_cbf;
    logic luma_coefficient_valid, luma_coefficient_ready;
    logic [7:0] luma_coefficient_address;
    logic signed [15:0] luma_coefficient;
    logic luma_coefficient_last, luma_bridge_done, luma_bridge_error;
    logic luma_bridge_busy;

    logic chroma_start_ready, chroma_descriptor_valid;
    logic chroma_descriptor_ready, chroma_cb_cbf, chroma_cr_cbf;
    logic chroma_coefficient_valid, chroma_coefficient_ready;
    logic [1:0] chroma_coefficient_plane;
    logic [5:0] chroma_coefficient_address;
    logic signed [15:0] chroma_coefficient;
    logic chroma_coefficient_last, chroma_block_done, chroma_block_error;
    logic chroma_protocol_error, chroma_parameter_error, chroma_busy;

    logic nal_ctu_start_ready, nal_cu_ready;
    logic nal_y_ready, nal_cb_ready, nal_cr_ready;
    logic nal_y_done, nal_cb_done, nal_cr_done;
    logic nal_ctu_done, nal_done, nal_parameter_error, nal_protocol_error;
    logic nal_busy;

    wire start_fire = start_valid && start_ready;
    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;
    wire luma_descriptor_fire = luma_cu_valid && luma_cu_ready;
    wire chroma_start_valid = luma_cu_valid && ctu_active &&
        !luma_descriptor_captured;
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
        !luma_bridge_busy && chroma_start_ready && !chroma_busy;
    assign y_ready = ctu_active && luma_s_ready;
    assign luma_cu_ready = chroma_start_ready && ctu_active &&
        !luma_descriptor_captured;
    assign chroma_descriptor_ready = ctu_active &&
        !chroma_descriptor_captured;
    assign current_luma_mode_dc = luma_mode_register;

    assign luma_coefficient_ready = nal_y_ready;
    assign chroma_coefficient_ready = chroma_coefficient_plane == 2'd1 ?
        nal_cb_ready : nal_cr_ready;
    assign parameter_error = nal_parameter_error || chroma_parameter_error;
    assign protocol_error = nal_protocol_error || luma_bridge_error ||
        chroma_protocol_error || chroma_block_error;
    assign busy = ctu_active || luma_bridge_busy || chroma_busy || nal_busy;

    hevc_tu16_cabac_bridge luma_bridge (
        .clk(clk), .rst_n(rst_n), .s_valid(y_valid && ctu_active),
        .s_ready(luma_s_ready), .s_prediction(y_prediction),
        .s_residual(y_residual), .s_quality(quality_register),
        .s_luma_mode_dc(y_luma_mode_dc), .m_valid(y_recon_valid),
        .m_ready(y_recon_ready), .m_reconstructed(y_reconstructed),
        .m_x(y_recon_x), .m_y(y_recon_y),
        .m_block_last(y_recon_block_last), .cu_valid(luma_cu_valid),
        .cu_ready(luma_cu_ready), .cu_luma_mode_dc(luma_cu_mode_dc),
        .cu_luma_cbf(luma_cu_cbf),
        .coefficient_valid(luma_coefficient_valid),
        .coefficient_ready(luma_coefficient_ready),
        .coefficient_raster_address(luma_coefficient_address),
        .coefficient(luma_coefficient),
        .coefficient_block_last(luma_coefficient_last),
        .block_done(luma_bridge_done), .block_error(luma_bridge_error),
        .busy(luma_bridge_busy)
    );

    hevc_chroma_ctu16_controller #(
        .FRAME_WIDTH(FRAME_WIDTH), .CTU_COLUMNS(CTU_COLUMNS)
    ) chroma_controller (
        .clk(clk), .rst_n(rst_n), .start_valid(chroma_start_valid),
        .start_ready(chroma_start_ready), .ctu_x(current_ctu_x),
        .top_available(top_available), .luma_mode_dc(luma_cu_mode_dc),
        .quality(quality_register), .cb_valid(cb_valid), .cb_ready(cb_ready),
        .cb_pixel(cb_pixel), .cr_valid(cr_valid), .cr_ready(cr_ready),
        .cr_pixel(cr_pixel), .m_valid(chroma_recon_valid),
        .m_ready(chroma_recon_ready), .m_plane(chroma_recon_plane),
        .m_reconstructed(chroma_reconstructed), .m_x(chroma_recon_x),
        .m_y(chroma_recon_y), .m_block_last(chroma_recon_block_last),
        .descriptor_valid(chroma_descriptor_valid),
        .descriptor_ready(chroma_descriptor_ready), .cb_cbf(chroma_cb_cbf),
        .cr_cbf(chroma_cr_cbf), .coefficient_valid(chroma_coefficient_valid),
        .coefficient_ready(chroma_coefficient_ready),
        .coefficient_plane(chroma_coefficient_plane),
        .coefficient_raster_address(chroma_coefficient_address),
        .coefficient(chroma_coefficient),
        .coefficient_block_last(chroma_coefficient_last),
        .block_done(chroma_block_done), .block_error(chroma_block_error),
        .protocol_error(chroma_protocol_error),
        .parameter_error(chroma_parameter_error), .busy(chroma_busy)
    );

    hevc_idr_ctu16_yuv_nal #(
        .CTU_COLUMNS(CTU_COLUMNS), .CTU_ROWS(CTU_ROWS),
        .SLICE_CTU_ROWS(SLICE_CTU_ROWS), .NAL_UNIT_TYPE(NAL_UNIT_TYPE)
    ) idr_nal (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid),
        .start_ready(start_ready), .slice_row(slice_row), .qp(qp),
        .no_output_of_prior_pics(no_output_of_prior_pics),
        .ctu_start_valid(ctu_start_valid && !ctu_active),
        .ctu_start_ready(nal_ctu_start_ready),
        .cu_valid(combined_descriptor_valid), .cu_ready(nal_cu_ready),
        .cu_luma_mode_dc(luma_mode_register),
        .cu_luma_cbf(luma_cbf_register), .cu_cb_cbf(cb_cbf_register),
        .cu_cr_cbf(cr_cbf_register),
        .y_valid(luma_coefficient_valid), .y_ready(nal_y_ready),
        .y_raster_address(luma_coefficient_address),
        .y_coefficient(luma_coefficient), .y_block_last(luma_coefficient_last),
        .cb_valid(chroma_coefficient_valid &&
            chroma_coefficient_plane == 2'd1), .cb_ready(nal_cb_ready),
        .cb_raster_address(chroma_coefficient_address),
        .cb_coefficient(chroma_coefficient),
        .cb_block_last(chroma_coefficient_last),
        .cr_valid(chroma_coefficient_valid &&
            chroma_coefficient_plane == 2'd2), .cr_ready(nal_cr_ready),
        .cr_raster_address(chroma_coefficient_address),
        .cr_coefficient(chroma_coefficient),
        .cr_block_last(chroma_coefficient_last),
        .m_valid(nal_valid), .m_ready(nal_ready), .m_byte(nal_byte),
        .m_last(nal_last), .current_ctu_x(current_ctu_x),
        .current_ctu_y(current_ctu_y), .y_block_done(nal_y_done),
        .cb_block_done(nal_cb_done), .cr_block_done(nal_cr_done),
        .ctu_done(nal_ctu_done), .done(nal_done),
        .parameter_error(nal_parameter_error),
        .protocol_error(nal_protocol_error), .busy(nal_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ctu_active <= 1'b0; quality_register <= 2'd1;
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
                ctu_active <= 1'b1; quality_register <= quality;
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
            end else if (nal_done && !ctu_active &&
                    !luma_bridge_busy && !chroma_busy) begin
                done <= 1'b1; nal_done_seen <= 1'b0;
            end
        end
    end

    logic unused_syntax_done;
    assign unused_syntax_done = ^{nal_y_done, nal_cb_done, nal_cr_done};
endmodule
