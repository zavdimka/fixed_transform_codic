module hevc_ctu16_yuv_syntax_path (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               ctu_start_valid,
    output logic               ctu_start_ready,
    input  logic               ctu_last_in_slice,
    input  logic               cu_valid,
    output logic               cu_ready,
    input  logic               cu_luma_mode_dc,
    input  logic               cu_luma_cbf,
    input  logic               cu_cb_cbf,
    input  logic               cu_cr_cbf,

    input  logic               y_valid,
    output logic               y_ready,
    input  logic [7:0]         y_raster_address,
    input  logic signed [15:0] y_coefficient,
    input  logic               y_block_last,
    input  logic               cb_valid,
    output logic               cb_ready,
    input  logic [5:0]         cb_raster_address,
    input  logic signed [15:0] cb_coefficient,
    input  logic               cb_block_last,
    input  logic               cr_valid,
    output logic               cr_ready,
    input  logic [5:0]         cr_raster_address,
    input  logic signed [15:0] cr_coefficient,
    input  logic               cr_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [1:0]         m_kind,
    output logic               m_bin,
    output logic [7:0]         m_context_address,
    output logic               m_last,
    output logic [1:0]         active_coefficient_plane,
    output logic               y_block_done,
    output logic               cb_block_done,
    output logic               cr_block_done,
    output logic               ctu_done,
    output logic               slice_termination,
    output logic               protocol_error,
    output logic               busy
);
    logic y_m_valid, y_m_ready, y_m_bin, y_m_bypass;
    logic [1:0] y_m_source, y_m_level_kind;
    logic [4:0] y_m_context_index;
    logic y_m_last_axis_y, y_m_coded_sub_block, y_input_error, y_busy;
    logic cb_m_valid, cb_m_ready, cb_m_bin, cb_m_bypass;
    logic [1:0] cb_m_source, cb_m_level_kind;
    logic [4:0] cb_m_context_index;
    logic cb_m_last_axis_y, cb_m_coded_sub_block, cb_input_error, cb_busy;
    logic cr_m_valid, cr_m_ready, cr_m_bin, cr_m_bypass;
    logic [1:0] cr_m_source, cr_m_level_kind;
    logic [4:0] cr_m_context_index;
    logic cr_m_last_axis_y, cr_m_coded_sub_block, cr_input_error, cr_busy;

    logic selected_valid, selected_ready, selected_bin, selected_bypass;
    logic [1:0] selected_source, selected_level_kind;
    logic [4:0] selected_context_index;
    logic selected_last_axis_y, selected_coded_sub_block;
    logic selected_block_done;
    logic [1:0] mapped_kind;
    logic [7:0] mapped_address;
    logic mapped_valid;
    logic scheduler_coefficient_ready;
    logic scheduler_error, scheduler_busy;

    logic unused_y_any, unused_cb_any, unused_cr_any;
    logic [7:0] unused_y_last, unused_y_scan;
    logic [15:0] unused_y_groups;
    logic [3:0] unused_y_group, unused_y_index;
    logic [5:0] unused_cb_last, unused_cr_last;
    logic [3:0] unused_cb_groups, unused_cr_groups;
    logic [5:0] unused_cb_scan, unused_cr_scan;
    logic [1:0] unused_cb_group, unused_cr_group;
    logic [3:0] unused_cb_index, unused_cr_index;

    always_comb begin
        selected_valid = y_m_valid;
        selected_bin = y_m_bin;
        selected_bypass = y_m_bypass;
        selected_source = y_m_source;
        selected_level_kind = y_m_level_kind;
        selected_context_index = y_m_context_index;
        selected_last_axis_y = y_m_last_axis_y;
        selected_coded_sub_block = y_m_coded_sub_block;
        selected_block_done = y_block_done;
        case (active_coefficient_plane)
            2'd1: begin
                selected_valid = cb_m_valid; selected_bin = cb_m_bin;
                selected_bypass = cb_m_bypass; selected_source = cb_m_source;
                selected_level_kind = cb_m_level_kind;
                selected_context_index = cb_m_context_index;
                selected_last_axis_y = cb_m_last_axis_y;
                selected_coded_sub_block = cb_m_coded_sub_block;
                selected_block_done = cb_block_done;
            end
            2'd2: begin
                selected_valid = cr_m_valid; selected_bin = cr_m_bin;
                selected_bypass = cr_m_bypass; selected_source = cr_m_source;
                selected_level_kind = cr_m_level_kind;
                selected_context_index = cr_m_context_index;
                selected_last_axis_y = cr_m_last_axis_y;
                selected_coded_sub_block = cr_m_coded_sub_block;
                selected_block_done = cr_block_done;
            end
            default: begin end
        endcase
    end

    assign selected_ready = scheduler_coefficient_ready;
    assign y_m_ready = active_coefficient_plane == 0 ? selected_ready : 1'b0;
    assign cb_m_ready = active_coefficient_plane == 1 ? selected_ready : 1'b0;
    assign cr_m_ready = active_coefficient_plane == 2 ? selected_ready : 1'b0;
    assign protocol_error = scheduler_error || y_input_error || cb_input_error ||
                            cr_input_error || (selected_valid && !mapped_valid);
    assign busy = scheduler_busy || y_busy || cb_busy || cr_busy;

    hevc_coefficient_syntax16 y_syntax (
        .clk(clk), .rst_n(rst_n), .s_valid(y_valid), .s_ready(y_ready),
        .s_raster_address(y_raster_address), .s_coefficient(y_coefficient),
        .s_block_last(y_block_last), .m_valid(y_m_valid), .m_ready(y_m_ready),
        .m_bin(y_m_bin), .m_bypass(y_m_bypass), .m_source(y_m_source),
        .m_level_kind(y_m_level_kind), .m_context_index(y_m_context_index),
        .m_last_axis_y(y_m_last_axis_y),
        .m_significance_coded_sub_block(y_m_coded_sub_block),
        .m_scan_position(unused_y_scan), .m_group_scan_position(unused_y_group),
        .m_coefficient_index(unused_y_index), .block_done(y_block_done),
        .any_nonzero(unused_y_any), .last_nonzero_scan_position(unused_y_last),
        .significant_group_flags(unused_y_groups), .busy(y_busy),
        .input_error(y_input_error)
    );

    hevc_coefficient_syntax8 cb_syntax (
        .clk(clk), .rst_n(rst_n), .s_valid(cb_valid), .s_ready(cb_ready),
        .s_raster_address(cb_raster_address), .s_coefficient(cb_coefficient),
        .s_block_last(cb_block_last), .m_valid(cb_m_valid), .m_ready(cb_m_ready),
        .m_bin(cb_m_bin), .m_bypass(cb_m_bypass), .m_source(cb_m_source),
        .m_level_kind(cb_m_level_kind), .m_context_index(cb_m_context_index),
        .m_last_axis_y(cb_m_last_axis_y),
        .m_significance_coded_sub_block(cb_m_coded_sub_block),
        .m_scan_position(unused_cb_scan),
        .m_group_scan_position(unused_cb_group),
        .m_coefficient_index(unused_cb_index), .block_done(cb_block_done),
        .any_nonzero(unused_cb_any), .last_nonzero_scan_position(unused_cb_last),
        .significant_group_flags(unused_cb_groups), .busy(cb_busy),
        .input_error(cb_input_error)
    );

    hevc_coefficient_syntax8 cr_syntax (
        .clk(clk), .rst_n(rst_n), .s_valid(cr_valid), .s_ready(cr_ready),
        .s_raster_address(cr_raster_address), .s_coefficient(cr_coefficient),
        .s_block_last(cr_block_last), .m_valid(cr_m_valid), .m_ready(cr_m_ready),
        .m_bin(cr_m_bin), .m_bypass(cr_m_bypass), .m_source(cr_m_source),
        .m_level_kind(cr_m_level_kind), .m_context_index(cr_m_context_index),
        .m_last_axis_y(cr_m_last_axis_y),
        .m_significance_coded_sub_block(cr_m_coded_sub_block),
        .m_scan_position(unused_cr_scan),
        .m_group_scan_position(unused_cr_group),
        .m_coefficient_index(unused_cr_index), .block_done(cr_block_done),
        .any_nonzero(unused_cr_any), .last_nonzero_scan_position(unused_cr_last),
        .significant_group_flags(unused_cr_groups), .busy(cr_busy),
        .input_error(cr_input_error)
    );

    hevc_coefficient_context_map context_map (
        .s_bypass(selected_bypass), .s_source(selected_source),
        .s_level_kind(selected_level_kind),
        .s_context_index(selected_context_index),
        .s_last_axis_y(selected_last_axis_y),
        .s_significance_coded_sub_block(selected_coded_sub_block),
        .m_cabac_kind(mapped_kind), .m_context_address(mapped_address),
        .m_context_valid(mapped_valid)
    );

    hevc_ctu16_syntax_scheduler scheduler (
        .clk(clk), .rst_n(rst_n), .ctu_start_valid(ctu_start_valid),
        .ctu_start_ready(ctu_start_ready), .ctu_last_in_slice(ctu_last_in_slice),
        .cu_valid(cu_valid), .cu_ready(cu_ready),
        .cu_luma_mode_dc(cu_luma_mode_dc), .cu_luma_cbf(cu_luma_cbf),
        .cu_cb_cbf(cu_cb_cbf), .cu_cr_cbf(cu_cr_cbf),
        .coefficient_valid(selected_valid && mapped_valid),
        .coefficient_ready(scheduler_coefficient_ready),
        .coefficient_plane(active_coefficient_plane),
        .coefficient_kind(mapped_kind), .coefficient_bin(selected_bin),
        .coefficient_context_address(mapped_address),
        .coefficient_block_done(selected_block_done),
        .m_valid(m_valid), .m_ready(m_ready), .m_kind(m_kind), .m_bin(m_bin),
        .m_context_address(m_context_address), .m_last(m_last),
        .ctu_done(ctu_done), .slice_termination(slice_termination),
        .protocol_error(scheduler_error), .busy(scheduler_busy)
    );
endmodule
