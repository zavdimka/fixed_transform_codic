module hevc_ctu16_yuv_cabac (
    input logic clk, input logic rst_n,
    input logic cfg_valid, output logic cfg_ready,
    input logic [7:0] cfg_context_address,
    input logic [5:0] cfg_state_index, input logic cfg_mps,
    input logic context_init_valid, output logic context_init_ready,
    input logic [1:0] context_init_slice_type,
    input logic [5:0] context_init_qp,
    output logic context_init_done, output logic context_init_error,
    input logic slice_start_valid, output logic slice_start_ready,
    input logic ctu_start_valid, output logic ctu_start_ready,
    input logic ctu_last_in_slice,
    input logic cu_valid, output logic cu_ready,
    input logic cu_luma_mode_dc, input logic cu_luma_cbf,
    input logic cu_cb_cbf, input logic cu_cr_cbf,
    input logic y_valid, output logic y_ready,
    input logic [7:0] y_raster_address,
    input logic signed [15:0] y_coefficient, input logic y_block_last,
    input logic cb_valid, output logic cb_ready,
    input logic [5:0] cb_raster_address,
    input logic signed [15:0] cb_coefficient, input logic cb_block_last,
    input logic cr_valid, output logic cr_ready,
    input logic [5:0] cr_raster_address,
    input logic signed [15:0] cr_coefficient, input logic cr_block_last,
    output logic m_valid, input logic m_ready,
    output logic [7:0] m_byte, output logic m_last,
    output logic y_block_done, output logic cb_block_done,
    output logic cr_block_done, output logic ctu_done,
    output logic slice_done, output logic protocol_error, output logic busy
);
    logic slice_active;
    logic path_m_valid, path_m_ready, path_m_bin, unused_path_m_last;
    logic path_ctu_ready, path_cu_ready, path_y_ready, path_cb_ready, path_cr_ready;
    logic [1:0] path_m_kind, unused_active_plane;
    logic [7:0] path_m_context;
    logic path_error, path_busy, unused_slice_termination;
    logic cabac_s_ready, cabac_error, cabac_busy;
    logic [1:0] bin_fifo_count;
    logic bin_fifo_write_pointer, bin_fifo_read_pointer;
    logic [1:0] bin_fifo_kind [0:1];
    logic bin_fifo_bin [0:1];
    logic [7:0] bin_fifo_context [0:1];
    logic unused_update_valid, unused_update_mps;
    logic [7:0] unused_update_address;
    logic [5:0] unused_update_state;

    logic init_start_ready, init_cfg_valid, init_cfg_ready, init_cfg_mps, init_busy;
    logic [7:0] init_cfg_address;
    logic [5:0] init_cfg_state;
    logic cabac_cfg_valid, cabac_cfg_ready, cabac_cfg_mps;
    logic [7:0] cabac_cfg_address;
    logic [5:0] cabac_cfg_state;
    logic cabac_start_valid, cabac_start_ready;

    wire slice_start_eligible = !slice_active && !path_busy && !init_busy &&
                                !context_init_valid;
    wire slice_start_fire = slice_start_valid && slice_start_ready;
    wire bin_fifo_enqueue = path_m_valid && path_m_ready;
    wire bin_fifo_dequeue = (bin_fifo_count != 0) && cabac_s_ready;
    wire final_terminate_fire = bin_fifo_dequeue &&
        (bin_fifo_kind[bin_fifo_read_pointer] == 2'd2) &&
        bin_fifo_bin[bin_fifo_read_pointer];

    assign context_init_ready = init_start_ready && cabac_cfg_ready;
    assign cfg_ready = cabac_cfg_ready && !init_busy && !context_init_valid;
    assign init_cfg_ready = cabac_cfg_ready;
    assign cabac_cfg_valid = init_cfg_valid ||
        (cfg_valid && !init_busy && !context_init_valid);
    assign cabac_cfg_address = init_cfg_valid ? init_cfg_address : cfg_context_address;
    assign cabac_cfg_state = init_cfg_valid ? init_cfg_state : cfg_state_index;
    assign cabac_cfg_mps = init_cfg_valid ? init_cfg_mps : cfg_mps;
    assign cabac_start_valid = slice_start_valid && slice_start_eligible;
    assign slice_start_ready = cabac_start_ready && slice_start_eligible;
    assign path_m_ready = slice_active && (bin_fifo_count < 2);
    assign ctu_start_ready = slice_active && path_ctu_ready;
    assign cu_ready = slice_active && path_cu_ready;
    assign y_ready = slice_active && path_y_ready;
    assign cb_ready = slice_active && path_cb_ready;
    assign cr_ready = slice_active && path_cr_ready;
    assign protocol_error = path_error || cabac_error || context_init_error;
    assign busy = slice_active || path_busy || cabac_busy || init_busy;

    hevc_coefficient_context_init context_initializer (
        .clk(clk), .rst_n(rst_n),
        .start_valid(context_init_valid && cabac_cfg_ready),
        .start_ready(init_start_ready), .slice_type(context_init_slice_type),
        .qp(context_init_qp), .cfg_valid(init_cfg_valid),
        .cfg_ready(init_cfg_ready), .cfg_context_address(init_cfg_address),
        .cfg_state_index(init_cfg_state), .cfg_mps(init_cfg_mps),
        .done(context_init_done), .parameter_error(context_init_error),
        .busy(init_busy)
    );

    hevc_ctu16_yuv_syntax_path syntax_path (
        .clk(clk), .rst_n(rst_n),
        .ctu_start_valid(ctu_start_valid && slice_active),
        .ctu_start_ready(path_ctu_ready), .ctu_last_in_slice(ctu_last_in_slice),
        .cu_valid(cu_valid && slice_active), .cu_ready(path_cu_ready),
        .cu_luma_mode_dc(cu_luma_mode_dc), .cu_luma_cbf(cu_luma_cbf),
        .cu_cb_cbf(cu_cb_cbf), .cu_cr_cbf(cu_cr_cbf),
        .y_valid(y_valid && slice_active), .y_ready(path_y_ready),
        .y_raster_address(y_raster_address), .y_coefficient(y_coefficient),
        .y_block_last(y_block_last),
        .cb_valid(cb_valid && slice_active), .cb_ready(path_cb_ready),
        .cb_raster_address(cb_raster_address), .cb_coefficient(cb_coefficient),
        .cb_block_last(cb_block_last),
        .cr_valid(cr_valid && slice_active), .cr_ready(path_cr_ready),
        .cr_raster_address(cr_raster_address), .cr_coefficient(cr_coefficient),
        .cr_block_last(cr_block_last), .m_valid(path_m_valid),
        .m_ready(path_m_ready), .m_kind(path_m_kind), .m_bin(path_m_bin),
        .m_context_address(path_m_context), .m_last(unused_path_m_last),
        .active_coefficient_plane(unused_active_plane),
        .y_block_done(y_block_done), .cb_block_done(cb_block_done),
        .cr_block_done(cr_block_done), .ctu_done(ctu_done),
        .slice_termination(unused_slice_termination),
        .protocol_error(path_error), .busy(path_busy)
    );

    hevc_cabac_encoder cabac (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cabac_cfg_valid),
        .cfg_ready(cabac_cfg_ready), .cfg_context_address(cabac_cfg_address),
        .cfg_state_index(cabac_cfg_state), .cfg_mps(cabac_cfg_mps),
        .start_valid(cabac_start_valid), .start_ready(cabac_start_ready),
        .s_valid(bin_fifo_count != 0), .s_ready(cabac_s_ready),
        .s_kind(bin_fifo_kind[bin_fifo_read_pointer]),
        .s_bin(bin_fifo_bin[bin_fifo_read_pointer]),
        .s_context_address(bin_fifo_context[bin_fifo_read_pointer]),
        .m_valid(m_valid),
        .m_ready(m_ready), .m_byte(m_byte), .m_last(m_last),
        .context_update_valid(unused_update_valid),
        .context_update_address(unused_update_address),
        .context_update_state_index(unused_update_state),
        .context_update_mps(unused_update_mps), .slice_done(slice_done),
        .protocol_error(cabac_error), .busy(cabac_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bin_fifo_count <= 0;
            bin_fifo_write_pointer <= 0;
            bin_fifo_read_pointer <= 0;
        end else begin
            case ({bin_fifo_enqueue, bin_fifo_dequeue})
                2'b10: bin_fifo_count <= bin_fifo_count + 1'b1;
                2'b01: bin_fifo_count <= bin_fifo_count - 1'b1;
                default: bin_fifo_count <= bin_fifo_count;
            endcase
            if (bin_fifo_enqueue) begin
                bin_fifo_kind[bin_fifo_write_pointer] <= path_m_kind;
                bin_fifo_bin[bin_fifo_write_pointer] <= path_m_bin;
                bin_fifo_context[bin_fifo_write_pointer] <= path_m_context;
                bin_fifo_write_pointer <= !bin_fifo_write_pointer;
            end
            if (bin_fifo_dequeue)
                bin_fifo_read_pointer <= !bin_fifo_read_pointer;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) slice_active <= 1'b0;
        else begin
            if (slice_start_fire) slice_active <= 1'b1;
            if (final_terminate_fire) slice_active <= 1'b0;
        end
    end
endmodule
