module hevc_yuv_dual_reconstruction_bridge #(
    parameter integer FRAME_WIDTH = 1280,
    parameter integer CTU_COLUMNS = FRAME_WIDTH / 16
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start_valid,
    output logic start_ready,
    input  logic [6:0] ctu_x,
    input  logic top_available,
    input  logic [1:0] quality,

    input  logic y_valid,
    output logic y_ready,
    input  logic [7:0] y_prediction,
    input  logic signed [8:0] y_residual,
    input  logic y_luma_mode_dc,
    input  logic cb_valid,
    output logic cb_ready,
    input  logic [7:0] cb_pixel,
    input  logic cr_valid,
    output logic cr_ready,
    input  logic [7:0] cr_pixel,

    output logic y_recon_valid,
    input  logic y_recon_ready,
    output logic [7:0] y_reconstructed,
    output logic [3:0] y_recon_x,
    output logic [3:0] y_recon_y,
    output logic y_recon_block_last,
    output logic chroma_recon_valid,
    input  logic chroma_recon_ready,
    output logic [1:0] chroma_recon_plane,
    output logic [7:0] chroma_reconstructed,
    output logic [2:0] chroma_recon_x,
    output logic [2:0] chroma_recon_y,
    output logic chroma_recon_block_last,

    output logic luma_cu_valid,
    input  logic luma_cu_ready,
    output logic luma_cu_mode_dc,
    output logic luma_cu_cbf,
    output logic chroma_descriptor_valid,
    input  logic chroma_descriptor_ready,
    output logic cb_cbf,
    output logic cr_cbf,

    output logic y_coefficient_valid,
    input  logic y_coefficient_ready,
    output logic [7:0] y_coefficient_address,
    output logic signed [15:0] y_coefficient,
    output logic y_coefficient_last,
    output logic cb_coefficient_valid,
    input  logic cb_coefficient_ready,
    output logic [5:0] cb_coefficient_address,
    output logic signed [15:0] cb_coefficient,
    output logic cb_coefficient_last,
    output logic cr_coefficient_valid,
    input  logic cr_coefficient_ready,
    output logic [5:0] cr_coefficient_address,
    output logic signed [15:0] cr_coefficient,
    output logic cr_coefficient_last,

    output logic luma_block_done,
    output logic chroma_block_done,
    output logic block_error,
    output logic protocol_error,
    output logic parameter_error,
    output logic busy
);
    typedef enum logic [2:0] {
        IDLE, Y_COMMAND, Y_INPUT, CB_COMMAND,
        CB_INPUT, CR_START, CR_INPUT, WAIT_COMPLETE
    } state_t;
    state_t state;

    logic [6:0] latched_ctu_x;
    logic latched_top_available;
    logic [1:0] latched_quality;
    logic latched_luma_mode_dc;
    logic [7:0] y_input_count;

    logic dual_command_valid, dual_command_ready;
    logic dual_command_size8, dual_command_chroma;
    logic dual_s_valid, dual_s_ready;
    logic [7:0] dual_s_prediction;
    logic signed [8:0] dual_s_residual;
    logic dual_coefficient_valid;
    logic signed [15:0] dual_coefficient_data;
    logic [3:0] dual_coefficient_x, dual_coefficient_y;
    logic dual_coefficient_nonzero, dual_coefficient_last;
    logic dual_m_valid, dual_m_ready;
    logic [7:0] dual_m_reconstructed;
    logic [3:0] dual_m_x, dual_m_y;
    logic dual_m_last, dual_m_error, dual_done, dual_busy;

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

    logic [1:0] coefficient_plane, reconstruction_plane;
    logic y_any_nonzero, cb_any_nonzero, cr_any_nonzero;
    logic luma_descriptor_pending, chroma_descriptor_pending;
    logic luma_descriptor_sent, chroma_descriptor_sent;
    logic y_reconstruction_done, cb_reconstruction_done, cr_reconstruction_done;
    logic cb_commit_seen, cr_commit_seen;
    logic luma_done_sent, chroma_done_sent;
    logic error_latched;

    logic y_store_finished, cb_store_finished, cr_store_finished;
    logic y_store_write, cb_store_write, cr_store_write;
    logic y_store_complete, cb_store_complete, cr_store_complete;
    logic [7:0] coefficient_raster_address;

    wire start_fire = start_valid && start_ready;
    wire y_source_fire = y_valid && y_ready;
    wire predictor_output_fire = predictor_m_valid && predictor_m_ready;
    wire cb_start_fire = (state == CB_COMMAND) && dual_command_ready &&
        cb_ref_start_ready && predictor_start_ready;
    wire cr_start_fire = (state == CR_START) && cr_ref_start_ready &&
        predictor_start_ready;
    wire dual_coefficient_fire = dual_coefficient_valid;
    wire dual_output_fire = dual_m_valid && dual_m_ready;
    wire luma_descriptor_fire = luma_cu_valid && luma_cu_ready;
    wire chroma_descriptor_fire = chroma_descriptor_valid &&
        chroma_descriptor_ready;
    wire y_reconstructed_fire = y_recon_valid && y_recon_ready;
    wire chroma_reconstructed_fire = chroma_recon_valid && chroma_recon_ready;
    wire [7:0] selected_source_pixel = (state == CB_INPUT) ? cb_pixel : cr_pixel;
    wire selected_source_valid = (state == CB_INPUT) ? cb_valid :
        ((state == CR_INPUT) ? cr_valid : 1'b0);
    wire selected_ref_valid = (state == CB_INPUT) ? cb_ref_valid :
        ((state == CR_INPUT) ? cr_ref_valid : 1'b0);
    wire [7:0] selected_ref_top = (state == CB_INPUT) ? cb_ref_top : cr_ref_top;
    wire [7:0] selected_ref_left = (state == CB_INPUT) ? cb_ref_left : cr_ref_left;
    wire selected_ref_last = (state == CB_INPUT) ? cb_ref_last : cr_ref_last;
    wire coefficient_nonzero = dual_coefficient_nonzero;
    wire y_block_nonzero = y_any_nonzero || coefficient_nonzero;
    wire cb_block_nonzero = cb_any_nonzero || coefficient_nonzero;
    wire cr_block_nonzero = cr_any_nonzero || coefficient_nonzero;
    wire luma_complete = luma_descriptor_sent && y_store_finished &&
        y_reconstruction_done;
    wire chroma_complete = chroma_descriptor_sent && cb_store_finished &&
        cr_store_finished && cb_reconstruction_done && cr_reconstruction_done &&
        cb_commit_seen && cr_commit_seen;

    assign start_ready = (state == IDLE) && !dual_busy;
    assign y_ready = (state == Y_INPUT) && dual_s_ready;
    assign cb_ready = (state == CB_INPUT) && predictor_s_ready;
    assign cr_ready = (state == CR_INPUT) && predictor_s_ready;

    assign dual_command_valid = (state == Y_COMMAND) || cb_start_fire;
    assign dual_command_size8 = state != Y_COMMAND;
    assign dual_command_chroma = state != Y_COMMAND;
    assign dual_s_valid = (state == Y_INPUT) ? y_valid :
        (((state == CB_INPUT) || (state == CR_INPUT)) ? predictor_m_valid : 1'b0);
    assign dual_s_prediction = (state == Y_INPUT) ? y_prediction :
        predictor_prediction;
    assign dual_s_residual = (state == Y_INPUT) ? y_residual : predictor_residual;
    assign predictor_m_ready = ((state == CB_INPUT) || (state == CR_INPUT)) &&
        dual_s_ready;

    assign cb_ref_ready = (state == CB_INPUT) && predictor_ref_ready;
    assign cr_ref_ready = (state == CR_INPUT) && predictor_ref_ready;

    assign y_recon_valid = dual_m_valid && reconstruction_plane == 0;
    assign chroma_recon_valid = dual_m_valid && reconstruction_plane != 0;
    assign dual_m_ready = reconstruction_plane == 0 ? y_recon_ready :
        chroma_recon_ready;
    assign y_reconstructed = dual_m_reconstructed;
    assign y_recon_x = dual_m_x;
    assign y_recon_y = dual_m_y;
    assign y_recon_block_last = dual_m_last;
    assign chroma_recon_plane = reconstruction_plane;
    assign chroma_reconstructed = dual_m_reconstructed;
    assign chroma_recon_x = dual_m_x[2:0];
    assign chroma_recon_y = dual_m_y[2:0];
    assign chroma_recon_block_last = dual_m_last;

    assign luma_cu_valid = luma_descriptor_pending;
    assign luma_cu_mode_dc = latched_luma_mode_dc;
    assign luma_cu_cbf = y_any_nonzero;
    assign chroma_descriptor_valid = chroma_descriptor_pending;
    assign cb_cbf = cb_any_nonzero;
    assign cr_cbf = cr_any_nonzero;

    assign coefficient_raster_address = coefficient_plane == 0 ?
        {dual_coefficient_y, dual_coefficient_x} :
        {2'b00, dual_coefficient_y[2:0], dual_coefficient_x[2:0]};
    assign y_store_write = dual_coefficient_fire && coefficient_plane == 0;
    assign cb_store_write = dual_coefficient_fire && coefficient_plane == 1;
    assign cr_store_write = dual_coefficient_fire && coefficient_plane == 2;
    assign y_store_complete = y_store_write && dual_coefficient_last;
    assign cb_store_complete = cb_store_write && dual_coefficient_last;
    assign cr_store_complete = cr_store_write && dual_coefficient_last;

    assign parameter_error = cb_ref_parameter || cr_ref_parameter;
    assign protocol_error = predictor_error || cb_ref_error || cr_ref_error;
    assign block_error = error_latched || parameter_error || protocol_error;
    assign busy = state != IDLE || dual_busy || predictor_busy ||
        cb_ref_busy || cr_ref_busy || luma_descriptor_pending ||
        chroma_descriptor_pending;

    hevc_dual_reconstruction_core arithmetic (
        .clk, .rst_n, .command_valid(dual_command_valid),
        .command_ready(dual_command_ready),
        .command_size8(dual_command_size8),
        .command_chroma(dual_command_chroma),
        .command_quality(latched_quality), .s_valid(dual_s_valid),
        .s_ready(dual_s_ready), .s_prediction(dual_s_prediction),
        .s_residual(dual_s_residual),
        .coefficient_valid(dual_coefficient_valid), .coefficient_ready(1'b1),
        .coefficient_data(dual_coefficient_data),
        .coefficient_x(dual_coefficient_x), .coefficient_y(dual_coefficient_y),
        .coefficient_nonzero(dual_coefficient_nonzero),
        .coefficient_block_last(dual_coefficient_last),
        .m_valid(dual_m_valid), .m_ready(dual_m_ready),
        .m_reconstructed(dual_m_reconstructed), .m_x(dual_m_x), .m_y(dual_m_y),
        .m_block_last(dual_m_last), .m_block_error(dual_m_error),
        .done(dual_done), .busy(dual_busy));

    hevc_chroma_reference_line_store8 #(
        .FRAME_WIDTH(FRAME_WIDTH), .CTU_COLUMNS(CTU_COLUMNS)
    ) cb_reference_store (
        .clk, .rst_n, .start_valid(cb_start_fire),
        .start_ready(cb_ref_start_ready), .ctu_x(latched_ctu_x),
        .top_available(latched_top_available), .m_valid(cb_ref_valid),
        .m_ready(cb_ref_ready), .m_ref_top(cb_ref_top), .m_ref_left(cb_ref_left),
        .m_ref_last(cb_ref_last),
        .recon_valid(chroma_reconstructed_fire && reconstruction_plane == 1),
        .recon_pixel(dual_m_reconstructed), .recon_x(dual_m_x[2:0]),
        .recon_y(dual_m_y[2:0]), .recon_block_last(dual_m_last),
        .block_committed(cb_ref_committed), .protocol_error(cb_ref_error),
        .parameter_error(cb_ref_parameter), .busy(cb_ref_busy));

    hevc_chroma_reference_line_store8 #(
        .FRAME_WIDTH(FRAME_WIDTH), .CTU_COLUMNS(CTU_COLUMNS)
    ) cr_reference_store (
        .clk, .rst_n, .start_valid(cr_start_fire),
        .start_ready(cr_ref_start_ready), .ctu_x(latched_ctu_x),
        .top_available(latched_top_available), .m_valid(cr_ref_valid),
        .m_ready(cr_ref_ready), .m_ref_top(cr_ref_top), .m_ref_left(cr_ref_left),
        .m_ref_last(cr_ref_last),
        .recon_valid(chroma_reconstructed_fire && reconstruction_plane == 2),
        .recon_pixel(dual_m_reconstructed), .recon_x(dual_m_x[2:0]),
        .recon_y(dual_m_y[2:0]), .recon_block_last(dual_m_last),
        .block_committed(cr_ref_committed), .protocol_error(cr_ref_error),
        .parameter_error(cr_ref_parameter), .busy(cr_ref_busy));

    hevc_chroma_intra8 predictor (
        .clk, .rst_n, .start_valid(cb_start_fire || cr_start_fire),
        .start_ready(predictor_start_ready),
        .luma_mode_dc(latched_luma_mode_dc), .ref_valid(selected_ref_valid),
        .ref_ready(predictor_ref_ready), .ref_top(selected_ref_top),
        .ref_left(selected_ref_left), .ref_last(selected_ref_last),
        .s_valid(selected_source_valid), .s_ready(predictor_s_ready),
        .s_pixel(selected_source_pixel), .m_valid(predictor_m_valid),
        .m_ready(predictor_m_ready), .m_prediction(predictor_prediction),
        .m_residual(predictor_residual), .m_block_last(predictor_m_last),
        .done(predictor_done), .protocol_error(predictor_error),
        .busy(predictor_busy));

    hevc_coefficient_replay_store #(.ADDRESS_WIDTH(8)) y_store (
        .clk, .rst_n, .clear(start_fire), .write_enable(y_store_write),
        .write_address(coefficient_raster_address),
        .write_data(dual_coefficient_data), .block_complete(y_store_complete),
        .block_nonzero(y_block_nonzero), .m_valid(y_coefficient_valid),
        .m_ready(y_coefficient_ready), .m_address(y_coefficient_address),
        .m_data(y_coefficient), .m_block_last(y_coefficient_last),
        .finished(y_store_finished));
    hevc_coefficient_replay_store #(.ADDRESS_WIDTH(6)) cb_store (
        .clk, .rst_n, .clear(start_fire), .write_enable(cb_store_write),
        .write_address(coefficient_raster_address[5:0]),
        .write_data(dual_coefficient_data), .block_complete(cb_store_complete),
        .block_nonzero(cb_block_nonzero), .m_valid(cb_coefficient_valid),
        .m_ready(cb_coefficient_ready), .m_address(cb_coefficient_address),
        .m_data(cb_coefficient), .m_block_last(cb_coefficient_last),
        .finished(cb_store_finished));
    hevc_coefficient_replay_store #(.ADDRESS_WIDTH(6)) cr_store (
        .clk, .rst_n, .clear(start_fire), .write_enable(cr_store_write),
        .write_address(coefficient_raster_address[5:0]),
        .write_data(dual_coefficient_data), .block_complete(cr_store_complete),
        .block_nonzero(cr_block_nonzero), .m_valid(cr_coefficient_valid),
        .m_ready(cr_coefficient_ready), .m_address(cr_coefficient_address),
        .m_data(cr_coefficient), .m_block_last(cr_coefficient_last),
        .finished(cr_store_finished));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            latched_ctu_x <= '0;
            latched_top_available <= 1'b0;
            latched_quality <= 2'd1;
            latched_luma_mode_dc <= 1'b1;
            y_input_count <= '0;
            coefficient_plane <= '0;
            reconstruction_plane <= '0;
            y_any_nonzero <= 1'b0;
            cb_any_nonzero <= 1'b0;
            cr_any_nonzero <= 1'b0;
            luma_descriptor_pending <= 1'b0;
            chroma_descriptor_pending <= 1'b0;
            luma_descriptor_sent <= 1'b0;
            chroma_descriptor_sent <= 1'b0;
            y_reconstruction_done <= 1'b0;
            cb_reconstruction_done <= 1'b0;
            cr_reconstruction_done <= 1'b0;
            cb_commit_seen <= 1'b0;
            cr_commit_seen <= 1'b0;
            luma_done_sent <= 1'b0;
            chroma_done_sent <= 1'b0;
            error_latched <= 1'b0;
            luma_block_done <= 1'b0;
            chroma_block_done <= 1'b0;
        end else begin
            luma_block_done <= 1'b0;
            chroma_block_done <= 1'b0;

            if (start_fire) begin
                state <= Y_COMMAND;
                latched_ctu_x <= ctu_x;
                latched_top_available <= top_available;
                latched_quality <= quality;
                y_input_count <= '0;
                coefficient_plane <= '0;
                reconstruction_plane <= '0;
                y_any_nonzero <= 1'b0;
                cb_any_nonzero <= 1'b0;
                cr_any_nonzero <= 1'b0;
                luma_descriptor_pending <= 1'b0;
                chroma_descriptor_pending <= 1'b0;
                luma_descriptor_sent <= 1'b0;
                chroma_descriptor_sent <= 1'b0;
                y_reconstruction_done <= 1'b0;
                cb_reconstruction_done <= 1'b0;
                cr_reconstruction_done <= 1'b0;
                cb_commit_seen <= 1'b0;
                cr_commit_seen <= 1'b0;
                luma_done_sent <= 1'b0;
                chroma_done_sent <= 1'b0;
                error_latched <= 1'b0;
            end

            if ((state == Y_COMMAND) && dual_command_ready)
                state <= Y_INPUT;
            if (y_source_fire) begin
                if (y_input_count == 0)
                    latched_luma_mode_dc <= y_luma_mode_dc;
                if (y_input_count == 8'hff) begin
                    y_input_count <= '0;
                    state <= CB_COMMAND;
                end else
                    y_input_count <= y_input_count + 1'b1;
            end
            if (cb_start_fire)
                state <= CB_INPUT;
            if ((state == CB_INPUT) && predictor_output_fire && predictor_m_last)
                state <= CR_START;
            if (cr_start_fire)
                state <= CR_INPUT;
            if ((state == CR_INPUT) && predictor_output_fire && predictor_m_last)
                state <= WAIT_COMPLETE;

            if (dual_coefficient_fire) begin
                case (coefficient_plane)
                    0: y_any_nonzero <= y_block_nonzero;
                    1: cb_any_nonzero <= cb_block_nonzero;
                    default: cr_any_nonzero <= cr_block_nonzero;
                endcase
                if (dual_coefficient_last) begin
                    case (coefficient_plane)
                        0: begin
                            luma_descriptor_pending <= 1'b1;
                            coefficient_plane <= 1;
                        end
                        1: coefficient_plane <= 2;
                        default: begin
                            chroma_descriptor_pending <= 1'b1;
                            coefficient_plane <= 0;
                        end
                    endcase
                end
            end

            if (luma_descriptor_fire) begin
                luma_descriptor_pending <= 1'b0;
                luma_descriptor_sent <= 1'b1;
            end
            if (chroma_descriptor_fire) begin
                chroma_descriptor_pending <= 1'b0;
                chroma_descriptor_sent <= 1'b1;
            end

            if (dual_output_fire && dual_m_last) begin
                error_latched <= error_latched || dual_m_error;
                case (reconstruction_plane)
                    0: begin
                        y_reconstruction_done <= 1'b1;
                        reconstruction_plane <= 1;
                    end
                    1: begin
                        cb_reconstruction_done <= 1'b1;
                        reconstruction_plane <= 2;
                    end
                    default: begin
                        cr_reconstruction_done <= 1'b1;
                        reconstruction_plane <= 0;
                    end
                endcase
            end
            if (cb_ref_committed)
                cb_commit_seen <= 1'b1;
            if (cr_ref_committed)
                cr_commit_seen <= 1'b1;

            if (luma_complete && !luma_done_sent) begin
                luma_done_sent <= 1'b1;
                luma_block_done <= 1'b1;
            end
            if (chroma_complete && !chroma_done_sent) begin
                chroma_done_sent <= 1'b1;
                chroma_block_done <= 1'b1;
                state <= IDLE;
            end
        end
    end

    logic unused;
    assign unused = ^{dual_done, predictor_done, y_reconstructed_fire};
endmodule
