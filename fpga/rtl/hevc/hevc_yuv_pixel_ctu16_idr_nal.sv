/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module hevc_yuv_pixel_ctu16_idr_nal #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer FRAME_HEIGHT = 768,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16,
    parameter integer CTU_ROWS = FRAME_HEIGHT / 16,
    parameter integer SLICE_CTU_ROWS = 4,
    parameter logic [5:0] NAL_UNIT_TYPE = 6'd20
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start_valid,
    output logic       start_ready,
    input  logic [5:0] slice_row,
    input  logic [5:0] qp,
    input  logic       no_output_of_prior_pics,

    input  logic       ctu_start_valid,
    output logic       ctu_start_ready,
    input  logic [1:0] quality,

    input  logic       y_valid,
    output logic       y_ready,
    input  logic [7:0] y_pixel,
    input  logic       cb_valid,
    output logic       cb_ready,
    input  logic [7:0] cb_pixel,
    input  logic       cr_valid,
    output logic       cr_ready,
    input  logic [7:0] cr_pixel,

    output logic       y_recon_valid,
    input  logic       y_recon_ready,
    output logic [7:0] y_reconstructed,
    output logic [3:0] y_recon_x,
    output logic [3:0] y_recon_y,
    output logic       y_recon_block_last,
    output logic       chroma_recon_valid,
    input  logic       chroma_recon_ready,
    output logic [1:0] chroma_recon_plane,
    output logic [7:0] chroma_reconstructed,
    output logic [2:0] chroma_recon_x,
    output logic [2:0] chroma_recon_y,
    output logic       chroma_recon_block_last,

    output logic       nal_valid,
    input  logic       nal_ready,
    output logic [7:0] nal_byte,
    output logic       nal_last,
    output logic [6:0] current_ctu_x,
    output logic [5:0] current_ctu_y,
    output logic       current_luma_mode_dc,
    output logic       luma_tu_done,
    output logic       chroma_tu_done,
    output logic       ctu_done,
    output logic       done,
    output logic       parameter_error,
    output logic       protocol_error,
    output logic       busy
);
    logic core_ctu_start_ready;
    logic core_y_ready;
    logic core_y_recon_valid;
    logic [7:0] core_y_reconstructed;
    logic [3:0] core_y_recon_x;
    logic [3:0] core_y_recon_y;
    logic core_y_recon_block_last;
    logic core_parameter_error;
    logic core_protocol_error;
    logic core_busy;

    logic reference_start_ready;
    logic reference_valid;
    logic [7:0] reference_top;
    logic [7:0] reference_left;
    logic reference_last;
    logic reference_block_committed;
    logic reference_protocol_error;
    logic reference_parameter_error;
    logic reference_busy;

    logic frontend_start_ready;
    logic frontend_ref_ready;
    logic frontend_source_ready;
    logic frontend_valid;
    logic [7:0] frontend_prediction;
    logic signed [8:0] frontend_residual;
    logic frontend_luma_mode_dc;
    logic frontend_block_last;
    logic [16:0] frontend_dc_sad;
    logic [16:0] frontend_planar_sad;
    logic frontend_done;
    logic frontend_protocol_error;
    logic frontend_busy;

    logic [5:0] slice_base_y;

    wire start_fire = start_valid && start_ready;
    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;
    wire reconstructed_fire = core_y_recon_valid && y_recon_ready;
    wire top_available = current_ctu_y != slice_base_y;

    assign ctu_start_ready = core_ctu_start_ready &&
        reference_start_ready && frontend_start_ready;
    assign y_ready = frontend_source_ready;

    assign y_recon_valid = core_y_recon_valid;
    assign y_reconstructed = core_y_reconstructed;
    assign y_recon_x = core_y_recon_x;
    assign y_recon_y = core_y_recon_y;
    assign y_recon_block_last = core_y_recon_block_last;
    assign parameter_error = core_parameter_error || reference_parameter_error;
    assign protocol_error = core_protocol_error || reference_protocol_error ||
        frontend_protocol_error;
    assign busy = core_busy || reference_busy || frontend_busy;

    hevc_luma_reference_line_store16 #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .CTU_COLUMNS(CTU_COLUMNS)
    ) reference_store (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(ctu_start_fire),
        .start_ready(reference_start_ready),
        .ctu_x(current_ctu_x),
        .top_available(top_available),
        .m_valid(reference_valid),
        .m_ready(frontend_ref_ready),
        .m_ref_top(reference_top),
        .m_ref_left(reference_left),
        .m_ref_last(reference_last),
        .recon_valid(reconstructed_fire),
        .recon_pixel(core_y_reconstructed),
        .recon_x(core_y_recon_x),
        .recon_y(core_y_recon_y),
        .recon_block_last(core_y_recon_block_last),
        .block_committed(reference_block_committed),
        .protocol_error(reference_protocol_error),
        .parameter_error(reference_parameter_error),
        .busy(reference_busy)
    );

    hevc_intra_frontend16 luma_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(ctu_start_fire),
        .start_ready(frontend_start_ready),
        .ref_valid(reference_valid),
        .ref_ready(frontend_ref_ready),
        .ref_top(reference_top),
        .ref_left(reference_left),
        .ref_last(reference_last),
        .s_valid(y_valid),
        .s_ready(frontend_source_ready),
        .s_pixel(y_pixel),
        .m_valid(frontend_valid),
        .m_ready(core_y_ready),
        .m_prediction(frontend_prediction),
        .m_residual(frontend_residual),
        .m_luma_mode_dc(frontend_luma_mode_dc),
        .m_block_last(frontend_block_last),
        .dc_sad(frontend_dc_sad),
        .planar_sad(frontend_planar_sad),
        .done(frontend_done),
        .protocol_error(frontend_protocol_error),
        .busy(frontend_busy)
    );

    hevc_yuv_ctu16_idr_nal #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .CTU_COLUMNS(CTU_COLUMNS),
        .CTU_ROWS(CTU_ROWS),
        .SLICE_CTU_ROWS(SLICE_CTU_ROWS),
        .NAL_UNIT_TYPE(NAL_UNIT_TYPE)
    ) core (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .slice_row(slice_row), .qp(qp),
        .no_output_of_prior_pics(no_output_of_prior_pics),
        .ctu_start_valid(ctu_start_fire),
        .ctu_start_ready(core_ctu_start_ready),
        .y_valid(frontend_valid), .y_ready(core_y_ready),
        .y_prediction(frontend_prediction),
        .y_residual(frontend_residual), .quality(quality),
        .y_luma_mode_dc(frontend_luma_mode_dc),
        .cb_valid(cb_valid), .cb_ready(cb_ready), .cb_pixel(cb_pixel),
        .cr_valid(cr_valid), .cr_ready(cr_ready), .cr_pixel(cr_pixel),
        .y_recon_valid(core_y_recon_valid),
        .y_recon_ready(y_recon_ready),
        .y_reconstructed(core_y_reconstructed),
        .y_recon_x(core_y_recon_x), .y_recon_y(core_y_recon_y),
        .y_recon_block_last(core_y_recon_block_last),
        .chroma_recon_valid(chroma_recon_valid),
        .chroma_recon_ready(chroma_recon_ready),
        .chroma_recon_plane(chroma_recon_plane),
        .chroma_reconstructed(chroma_reconstructed),
        .chroma_recon_x(chroma_recon_x), .chroma_recon_y(chroma_recon_y),
        .chroma_recon_block_last(chroma_recon_block_last),
        .nal_valid(nal_valid), .nal_ready(nal_ready),
        .nal_byte(nal_byte), .nal_last(nal_last),
        .current_ctu_x(current_ctu_x), .current_ctu_y(current_ctu_y),
        .current_luma_mode_dc(current_luma_mode_dc),
        .luma_tu_done(luma_tu_done), .chroma_tu_done(chroma_tu_done),
        .ctu_done(ctu_done), .done(done),
        .parameter_error(core_parameter_error),
        .protocol_error(core_protocol_error), .busy(core_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n)
            slice_base_y <= 6'd0;
        else if (start_fire)
            slice_base_y <= 6'(slice_row * SLICE_CTU_ROWS);
    end

    logic unused_frontend_status;
    assign unused_frontend_status = ^{reference_block_committed,
        frontend_block_last, frontend_dc_sad, frontend_planar_sad,
        frontend_done};
endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
