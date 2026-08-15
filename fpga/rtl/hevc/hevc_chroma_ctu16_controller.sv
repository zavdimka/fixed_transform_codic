module hevc_chroma_ctu16_controller #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start_valid,
    output logic               start_ready,
    input  logic [6:0]         ctu_x,
    input  logic               top_available,
    input  logic               luma_mode_dc,
    input  logic [1:0]         quality,

    input  logic               cb_valid,
    output logic               cb_ready,
    input  logic [7:0]         cb_pixel,
    input  logic               cr_valid,
    output logic               cr_ready,
    input  logic [7:0]         cr_pixel,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [1:0]         m_plane,
    output logic [7:0]         m_reconstructed,
    output logic [2:0]         m_x,
    output logic [2:0]         m_y,
    output logic               m_block_last,

    output logic               descriptor_valid,
    input  logic               descriptor_ready,
    output logic               cb_cbf,
    output logic               cr_cbf,

    output logic               coefficient_valid,
    input  logic               coefficient_ready,
    output logic [1:0]         coefficient_plane,
    output logic [5:0]         coefficient_raster_address,
    output logic signed [15:0] coefficient,
    output logic               coefficient_block_last,

    output logic               block_done,
    output logic               block_error,
    output logic               protocol_error,
    output logic               parameter_error,
    output logic               busy
);
    typedef enum logic [2:0] {
        IDLE,
        CB_ACTIVE,
        START_CR,
        CR_ACTIVE,
        OUTPUT_DESCRIPTOR
    } state_t;

    state_t state;
    logic [6:0] latched_ctu_x;
    logic latched_top_available;
    logic latched_luma_mode_dc;
    logic [1:0] latched_quality;
    logic cb_cbf_register;
    logic cr_cbf_register;
    logic cb_commit_seen;
    logic cr_commit_seen;
    logic error_latched;

    logic cb_ref_start_ready, cb_ref_valid, cb_ref_ready;
    logic [7:0] cb_ref_top, cb_ref_left;
    logic cb_ref_last, cb_ref_committed, cb_ref_error, cb_ref_parameter;
    logic cb_ref_busy;
    logic cr_ref_start_ready, cr_ref_valid, cr_ref_ready;
    logic [7:0] cr_ref_top, cr_ref_left;
    logic cr_ref_last, cr_ref_committed, cr_ref_error, cr_ref_parameter;
    logic cr_ref_busy;

    logic predictor_start_ready, predictor_ref_ready, predictor_s_ready;
    logic predictor_m_valid, predictor_m_ready;
    logic [7:0] predictor_prediction;
    logic signed [8:0] predictor_residual;
    logic predictor_m_last, predictor_done, predictor_error, predictor_busy;

    logic bridge_s_ready, bridge_m_valid, bridge_m_ready;
    logic [7:0] bridge_m_reconstructed;
    logic [2:0] bridge_m_x, bridge_m_y;
    logic bridge_m_last;
    logic bridge_descriptor_valid, bridge_descriptor_ready, bridge_cbf;
    logic bridge_coefficient_valid, bridge_coefficient_ready;
    logic [5:0] bridge_coefficient_address;
    logic signed [15:0] bridge_coefficient;
    logic bridge_coefficient_last;
    logic bridge_done, bridge_error, bridge_busy;

    wire cb_active = state == CB_ACTIVE;
    wire cr_active = state == CR_ACTIVE;
    wire plane_active = cb_active || cr_active;
    wire start_fire = start_valid && start_ready;
    wire cr_start_fire = (state == START_CR) && cr_ref_start_ready &&
        predictor_start_ready && !bridge_busy;
    wire predictor_start_valid = start_fire || cr_start_fire;
    wire selected_source_valid = cb_active ? cb_valid :
        (cr_active ? cr_valid : 1'b0);
    wire [7:0] selected_source_pixel = cb_active ? cb_pixel : cr_pixel;
    wire selected_ref_valid = cb_active ? cb_ref_valid :
        (cr_active ? cr_ref_valid : 1'b0);
    wire [7:0] selected_ref_top = cb_active ? cb_ref_top : cr_ref_top;
    wire [7:0] selected_ref_left = cb_active ? cb_ref_left : cr_ref_left;
    wire selected_ref_last = cb_active ? cb_ref_last : cr_ref_last;
    wire reconstructed_fire = m_valid && m_ready;
    wire descriptor_fire = descriptor_valid && descriptor_ready;
    wire bridge_descriptor_fire = bridge_descriptor_valid &&
        bridge_descriptor_ready;

    assign start_ready = (state == IDLE) && cb_ref_start_ready &&
        predictor_start_ready && !bridge_busy;
    assign cb_ready = cb_active && predictor_s_ready;
    assign cr_ready = cr_active && predictor_s_ready;

    assign predictor_m_ready = bridge_s_ready;
    assign bridge_m_ready = plane_active && m_ready;
    assign m_valid = plane_active && bridge_m_valid;
    assign m_plane = cb_active ? 2'd1 : 2'd2;
    assign m_reconstructed = bridge_m_reconstructed;
    assign m_x = bridge_m_x;
    assign m_y = bridge_m_y;
    assign m_block_last = bridge_m_last;

    assign bridge_descriptor_ready = plane_active;
    assign descriptor_valid = state == OUTPUT_DESCRIPTOR;
    assign cb_cbf = cb_cbf_register;
    assign cr_cbf = cr_cbf_register;

    assign bridge_coefficient_ready = plane_active && coefficient_ready;
    assign coefficient_valid = plane_active && bridge_coefficient_valid;
    assign coefficient_plane = cb_active ? 2'd1 : 2'd2;
    assign coefficient_raster_address = bridge_coefficient_address;
    assign coefficient = bridge_coefficient;
    assign coefficient_block_last = bridge_coefficient_last;

    assign cb_ref_ready = cb_active && predictor_ref_ready;
    assign cr_ref_ready = cr_active && predictor_ref_ready;
    assign parameter_error = cb_ref_parameter || cr_ref_parameter;
    assign protocol_error = error_latched || cb_ref_error || cr_ref_error ||
        predictor_error;
    assign block_error = error_latched || bridge_error || parameter_error;
    assign busy = (state != IDLE) || cb_ref_busy || cr_ref_busy ||
        predictor_busy || bridge_busy;

    hevc_chroma_reference_line_store8 #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .CTU_COLUMNS(CTU_COLUMNS)
    ) cb_reference_store (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_fire), .start_ready(cb_ref_start_ready),
        .ctu_x(ctu_x), .top_available(top_available),
        .m_valid(cb_ref_valid), .m_ready(cb_ref_ready),
        .m_ref_top(cb_ref_top), .m_ref_left(cb_ref_left),
        .m_ref_last(cb_ref_last),
        .recon_valid(reconstructed_fire && cb_active),
        .recon_pixel(bridge_m_reconstructed),
        .recon_x(bridge_m_x), .recon_y(bridge_m_y),
        .recon_block_last(bridge_m_last),
        .block_committed(cb_ref_committed),
        .protocol_error(cb_ref_error), .parameter_error(cb_ref_parameter),
        .busy(cb_ref_busy)
    );

    hevc_chroma_reference_line_store8 #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .CTU_COLUMNS(CTU_COLUMNS)
    ) cr_reference_store (
        .clk(clk), .rst_n(rst_n),
        .start_valid(cr_start_fire), .start_ready(cr_ref_start_ready),
        .ctu_x(latched_ctu_x), .top_available(latched_top_available),
        .m_valid(cr_ref_valid), .m_ready(cr_ref_ready),
        .m_ref_top(cr_ref_top), .m_ref_left(cr_ref_left),
        .m_ref_last(cr_ref_last),
        .recon_valid(reconstructed_fire && cr_active),
        .recon_pixel(bridge_m_reconstructed),
        .recon_x(bridge_m_x), .recon_y(bridge_m_y),
        .recon_block_last(bridge_m_last),
        .block_committed(cr_ref_committed),
        .protocol_error(cr_ref_error), .parameter_error(cr_ref_parameter),
        .busy(cr_ref_busy)
    );

    hevc_chroma_intra8 predictor (
        .clk(clk), .rst_n(rst_n),
        .start_valid(predictor_start_valid),
        .start_ready(predictor_start_ready),
        .luma_mode_dc(start_fire ? luma_mode_dc : latched_luma_mode_dc),
        .ref_valid(selected_ref_valid), .ref_ready(predictor_ref_ready),
        .ref_top(selected_ref_top), .ref_left(selected_ref_left),
        .ref_last(selected_ref_last),
        .s_valid(selected_source_valid), .s_ready(predictor_s_ready),
        .s_pixel(selected_source_pixel),
        .m_valid(predictor_m_valid), .m_ready(predictor_m_ready),
        .m_prediction(predictor_prediction),
        .m_residual(predictor_residual),
        .m_block_last(predictor_m_last),
        .done(predictor_done), .protocol_error(predictor_error),
        .busy(predictor_busy)
    );

    hevc_chroma_tu8_cabac_bridge bridge (
        .clk(clk), .rst_n(rst_n),
        .s_valid(predictor_m_valid), .s_ready(bridge_s_ready),
        .s_prediction(predictor_prediction),
        .s_residual(predictor_residual), .s_quality(latched_quality),
        .m_valid(bridge_m_valid), .m_ready(bridge_m_ready),
        .m_reconstructed(bridge_m_reconstructed),
        .m_x(bridge_m_x), .m_y(bridge_m_y),
        .m_block_last(bridge_m_last),
        .descriptor_valid(bridge_descriptor_valid),
        .descriptor_ready(bridge_descriptor_ready),
        .descriptor_cbf(bridge_cbf),
        .coefficient_valid(bridge_coefficient_valid),
        .coefficient_ready(bridge_coefficient_ready),
        .coefficient_raster_address(bridge_coefficient_address),
        .coefficient(bridge_coefficient),
        .coefficient_block_last(bridge_coefficient_last),
        .block_done(bridge_done), .block_error(bridge_error),
        .busy(bridge_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_ctu_x <= 7'd0;
            latched_top_available <= 1'b0;
            latched_luma_mode_dc <= 1'b1;
            latched_quality <= 2'd1;
            cb_cbf_register <= 1'b0;
            cr_cbf_register <= 1'b0;
            cb_commit_seen <= 1'b0;
            cr_commit_seen <= 1'b0;
            error_latched <= 1'b0;
            block_done <= 1'b0;
        end else begin
            block_done <= 1'b0;

            if (start_fire) begin
                latched_ctu_x <= ctu_x;
                latched_top_available <= top_available;
                latched_luma_mode_dc <= luma_mode_dc;
                latched_quality <= quality;
                cb_cbf_register <= 1'b0;
                cr_cbf_register <= 1'b0;
                cb_commit_seen <= 1'b0;
                cr_commit_seen <= 1'b0;
                error_latched <= 1'b0;
                state <= CB_ACTIVE;
            end

            if (cb_ref_committed)
                cb_commit_seen <= 1'b1;
            if (cr_ref_committed)
                cr_commit_seen <= 1'b1;

            if (bridge_descriptor_fire) begin
                if (cb_active)
                    cb_cbf_register <= bridge_cbf;
                else if (cr_active)
                    cr_cbf_register <= bridge_cbf;
            end

            if (cb_active && bridge_done) begin
                error_latched <= error_latched || bridge_error ||
                    cb_ref_error || predictor_error ||
                    !(cb_commit_seen || cb_ref_committed);
                state <= START_CR;
            end

            if (cr_start_fire)
                state <= CR_ACTIVE;

            if (cr_active && bridge_done) begin
                error_latched <= error_latched || bridge_error ||
                    cr_ref_error || predictor_error ||
                    !(cr_commit_seen || cr_ref_committed);
                state <= OUTPUT_DESCRIPTOR;
            end

            if (descriptor_fire) begin
                state <= IDLE;
                block_done <= 1'b1;
            end
        end
    end

    logic unused;
    assign unused = predictor_m_last ^ predictor_done;
endmodule
