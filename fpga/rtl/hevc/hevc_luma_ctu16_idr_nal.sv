module hevc_luma_ctu16_idr_nal #(
    parameter integer CTU_COLUMNS = 80,
    parameter integer CTU_ROWS = 48,
    parameter integer SLICE_CTU_ROWS = 4,
    parameter logic [5:0] NAL_UNIT_TYPE = 6'd20
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start_valid,
    output logic              start_ready,
    input  logic [5:0]        slice_row,
    input  logic [5:0]        qp,
    input  logic              no_output_of_prior_pics,

    input  logic              ctu_start_valid,
    output logic              ctu_start_ready,

    input  logic              s_valid,
    output logic              s_ready,
    input  logic [7:0]        s_prediction,
    input  logic signed [8:0] s_residual,
    input  logic [1:0]        s_quality,
    input  logic              s_luma_mode_dc,

    output logic              recon_valid,
    input  logic              recon_ready,
    output logic [7:0]        recon_pixel,
    output logic [3:0]        recon_x,
    output logic [3:0]        recon_y,
    output logic              recon_block_last,

    output logic              nal_valid,
    input  logic              nal_ready,
    output logic [7:0]        nal_byte,
    output logic              nal_last,

    output logic [6:0]        current_ctu_x,
    output logic [5:0]        current_ctu_y,
    output logic              tu_done,
    output logic              ctu_done,
    output logic              done,
    output logic              parameter_error,
    output logic              protocol_error,
    output logic              busy
);
    logic ctu_active;
    logic tu_done_seen;
    logic nal_ctu_done_seen;
    logic nal_done_seen;

    logic bridge_s_ready;
    logic bridge_cu_valid;
    logic bridge_cu_ready;
    logic bridge_cu_luma_mode_dc;
    logic bridge_cu_luma_cbf;
    logic bridge_coefficient_valid;
    logic bridge_coefficient_ready;
    logic [7:0] bridge_coefficient_address;
    logic signed [15:0] bridge_coefficient;
    logic bridge_coefficient_last;
    logic bridge_done;
    logic bridge_error;
    logic bridge_busy;

    logic nal_ctu_start_ready;
    logic nal_ctu_done;
    logic nal_done;
    logic unused_nal_block_done;
    logic nal_parameter_error;
    logic nal_protocol_error;
    logic nal_busy;

    wire ctu_start_fire = ctu_start_valid && ctu_start_ready;
    wire joined_ctu_done = ctu_active &&
        (tu_done_seen || bridge_done) &&
        (nal_ctu_done_seen || nal_ctu_done);

    assign ctu_start_ready = !ctu_active && nal_ctu_start_ready;
    assign s_ready = ctu_active && bridge_s_ready;
    assign tu_done = bridge_done;
    assign parameter_error = nal_parameter_error;
    assign protocol_error = nal_protocol_error || bridge_error;
    assign busy = ctu_active || bridge_busy || nal_busy;

    hevc_tu16_cabac_bridge tu_bridge (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid && ctu_active),
        .s_ready(bridge_s_ready),
        .s_prediction(s_prediction),
        .s_residual(s_residual),
        .s_quality(s_quality),
        .s_luma_mode_dc(s_luma_mode_dc),
        .m_valid(recon_valid),
        .m_ready(recon_ready),
        .m_reconstructed(recon_pixel),
        .m_x(recon_x),
        .m_y(recon_y),
        .m_block_last(recon_block_last),
        .cu_valid(bridge_cu_valid),
        .cu_ready(bridge_cu_ready),
        .cu_luma_mode_dc(bridge_cu_luma_mode_dc),
        .cu_luma_cbf(bridge_cu_luma_cbf),
        .coefficient_valid(bridge_coefficient_valid),
        .coefficient_ready(bridge_coefficient_ready),
        .coefficient_raster_address(bridge_coefficient_address),
        .coefficient(bridge_coefficient),
        .coefficient_block_last(bridge_coefficient_last),
        .block_done(bridge_done),
        .block_error(bridge_error),
        .busy(bridge_busy)
    );

    hevc_idr_ctu16_nal #(
        .CTU_COLUMNS(CTU_COLUMNS),
        .CTU_ROWS(CTU_ROWS),
        .SLICE_CTU_ROWS(SLICE_CTU_ROWS),
        .NAL_UNIT_TYPE(NAL_UNIT_TYPE)
    ) idr_nal (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(start_valid),
        .start_ready(start_ready),
        .slice_row(slice_row),
        .qp(qp),
        .no_output_of_prior_pics(no_output_of_prior_pics),
        .ctu_start_valid(ctu_start_valid && !ctu_active),
        .ctu_start_ready(nal_ctu_start_ready),
        .cu_valid(bridge_cu_valid),
        .cu_ready(bridge_cu_ready),
        .cu_luma_mode_dc(bridge_cu_luma_mode_dc),
        .cu_luma_cbf(bridge_cu_luma_cbf),
        .s_valid(bridge_coefficient_valid),
        .s_ready(bridge_coefficient_ready),
        .s_raster_address(bridge_coefficient_address),
        .s_coefficient(bridge_coefficient),
        .s_block_last(bridge_coefficient_last),
        .m_valid(nal_valid),
        .m_ready(nal_ready),
        .m_byte(nal_byte),
        .m_last(nal_last),
        .current_ctu_x(current_ctu_x),
        .current_ctu_y(current_ctu_y),
        .block_done(unused_nal_block_done),
        .ctu_done(nal_ctu_done),
        .done(nal_done),
        .parameter_error(nal_parameter_error),
        .protocol_error(nal_protocol_error),
        .busy(nal_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ctu_active <= 1'b0;
            tu_done_seen <= 1'b0;
            nal_ctu_done_seen <= 1'b0;
            nal_done_seen <= 1'b0;
            ctu_done <= 1'b0;
            done <= 1'b0;
        end else begin
            ctu_done <= 1'b0;
            done <= 1'b0;

            if (bridge_done)
                tu_done_seen <= 1'b1;
            if (nal_ctu_done)
                nal_ctu_done_seen <= 1'b1;
            if (nal_done)
                nal_done_seen <= 1'b1;

            if (ctu_start_fire) begin
                ctu_active <= 1'b1;
                tu_done_seen <= 1'b0;
                nal_ctu_done_seen <= 1'b0;
            end

            if (joined_ctu_done) begin
                ctu_active <= 1'b0;
                tu_done_seen <= 1'b0;
                nal_ctu_done_seen <= 1'b0;
                ctu_done <= 1'b1;
                if (nal_done_seen || nal_done) begin
                    done <= 1'b1;
                    nal_done_seen <= 1'b0;
                end
            end else if (nal_done && !ctu_active && !bridge_busy) begin
                done <= 1'b1;
                nal_done_seen <= 1'b0;
            end
        end
    end
endmodule
