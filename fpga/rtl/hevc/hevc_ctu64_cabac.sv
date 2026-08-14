module hevc_ctu64_cabac (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               cfg_valid,
    output logic               cfg_ready,
    input  logic [7:0]         cfg_context_address,
    input  logic [5:0]         cfg_state_index,
    input  logic               cfg_mps,

    input  logic               context_init_valid,
    output logic               context_init_ready,
    input  logic [1:0]         context_init_slice_type,
    input  logic [5:0]         context_init_qp,
    output logic               context_init_done,
    output logic               context_init_error,

    input  logic               slice_start_valid,
    output logic               slice_start_ready,

    input  logic               ctu_start_valid,
    output logic               ctu_start_ready,
    input  logic [5:0]         ctu_x,
    input  logic               ctu_last_in_slice,

    input  logic               cu_valid,
    output logic               cu_ready,
    input  logic               cu_luma_mode_dc,
    input  logic               cu_luma_cbf,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_byte,
    output logic               m_last,

    output logic               block_done,
    output logic               ctu_done,
    output logic               slice_done,
    output logic               protocol_error,
    output logic               busy
);
    logic slice_active;
    logic [1:0] outstanding_blocks;
    logic [7:0] input_count;
    logic wrapper_error;

    logic syntax_s_ready;
    logic syntax_m_valid;
    logic syntax_m_ready;
    logic syntax_m_bin;
    logic syntax_m_bypass;
    logic [1:0] syntax_m_source;
    logic [1:0] syntax_m_level_kind;
    logic [4:0] syntax_m_context_index;
    logic syntax_m_last_axis_y;
    logic syntax_m_coded_sub_block;
    logic syntax_block_done;
    logic unused_syntax_any_nonzero;
    logic [7:0] unused_syntax_last_position;
    logic [15:0] unused_syntax_group_flags;
    logic [7:0] unused_syntax_scan_position;
    logic [3:0] unused_syntax_group_position;
    logic [3:0] unused_syntax_coefficient_index;
    logic unused_syntax_busy;
    logic syntax_input_error;

    logic [1:0] mapped_cabac_kind;
    logic [7:0] mapped_context_address;
    logic mapped_context_valid;

    logic scheduler_ctu_start_ready;
    logic scheduler_cu_ready;
    logic scheduler_coefficient_ready;
    logic scheduler_m_valid;
    logic scheduler_m_ready;
    logic [1:0] scheduler_m_kind;
    logic scheduler_m_bin;
    logic [7:0] scheduler_m_context_address;
    logic unused_scheduler_m_last;
    logic scheduler_ctu_done;
    logic unused_scheduler_slice_termination;
    logic scheduler_protocol_error;
    logic scheduler_busy;

    logic cabac_s_ready;
    logic cabac_protocol_error;
    logic cabac_busy;
    logic unused_context_update_valid;
    logic [7:0] unused_context_update_address;
    logic [5:0] unused_context_update_state;
    logic unused_context_update_mps;

    logic init_start_ready;
    logic init_cfg_valid;
    logic init_cfg_ready;
    logic [7:0] init_cfg_context_address;
    logic [5:0] init_cfg_state_index;
    logic init_cfg_mps;
    logic init_busy;

    logic cabac_cfg_valid;
    logic cabac_cfg_ready;
    logic [7:0] cabac_cfg_context_address;
    logic [5:0] cabac_cfg_state_index;
    logic cabac_cfg_mps;
    logic cabac_start_valid;
    logic cabac_start_ready;

    wire coefficient_fire = s_valid && s_ready;
    wire coefficient_complete = coefficient_fire &&
        (s_block_last || (input_count == 8'hff));
    wire syntax_fire = syntax_m_valid && syntax_m_ready;
    wire slice_start_eligible = !slice_active && !scheduler_busy &&
        !init_busy && !context_init_valid &&
        (outstanding_blocks == 0) && (input_count == 0);
    wire slice_start_fire = slice_start_valid && slice_start_ready;
    wire scheduler_output_fire = scheduler_m_valid && scheduler_m_ready;
    wire final_terminate_fire = scheduler_output_fire &&
        (scheduler_m_kind == 2'd2) && scheduler_m_bin;

    assign s_ready = slice_active && syntax_s_ready;
    assign syntax_m_ready = mapped_context_valid ?
        scheduler_coefficient_ready : 1'b1;

    assign ctu_start_ready = slice_active && scheduler_ctu_start_ready;
    assign cu_ready = slice_active && scheduler_cu_ready;
    assign scheduler_m_ready = slice_active && cabac_s_ready;

    assign context_init_ready = init_start_ready && cabac_cfg_ready;
    assign cfg_ready = cabac_cfg_ready && !init_busy &&
        !context_init_valid;
    assign init_cfg_ready = cabac_cfg_ready;
    assign cabac_cfg_valid = init_cfg_valid ||
        (cfg_valid && !init_busy && !context_init_valid);
    assign cabac_cfg_context_address = init_cfg_valid ?
        init_cfg_context_address : cfg_context_address;
    assign cabac_cfg_state_index = init_cfg_valid ?
        init_cfg_state_index : cfg_state_index;
    assign cabac_cfg_mps = init_cfg_valid ? init_cfg_mps : cfg_mps;

    assign cabac_start_valid = slice_start_valid && slice_start_eligible;
    assign slice_start_ready = cabac_start_ready && slice_start_eligible;

    assign block_done = syntax_block_done;
    assign ctu_done = scheduler_ctu_done;
    assign protocol_error = wrapper_error || syntax_input_error ||
        scheduler_protocol_error || cabac_protocol_error ||
        context_init_error;
    assign busy = slice_active || scheduler_busy || cabac_busy || init_busy ||
        (outstanding_blocks != 0) || (input_count != 0);

    hevc_coefficient_context_init context_initializer (
        .clk(clk),
        .rst_n(rst_n),
        .start_valid(context_init_valid && cabac_cfg_ready),
        .start_ready(init_start_ready),
        .slice_type(context_init_slice_type),
        .qp(context_init_qp),
        .cfg_valid(init_cfg_valid),
        .cfg_ready(init_cfg_ready),
        .cfg_context_address(init_cfg_context_address),
        .cfg_state_index(init_cfg_state_index),
        .cfg_mps(init_cfg_mps),
        .done(context_init_done),
        .parameter_error(context_init_error),
        .busy(init_busy)
    );

    hevc_coefficient_syntax16 syntax (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(s_valid && slice_active),
        .s_ready(syntax_s_ready),
        .s_raster_address(s_raster_address),
        .s_coefficient(s_coefficient),
        .s_block_last(s_block_last),
        .m_valid(syntax_m_valid),
        .m_ready(syntax_m_ready),
        .m_bin(syntax_m_bin),
        .m_bypass(syntax_m_bypass),
        .m_source(syntax_m_source),
        .m_level_kind(syntax_m_level_kind),
        .m_context_index(syntax_m_context_index),
        .m_last_axis_y(syntax_m_last_axis_y),
        .m_significance_coded_sub_block(syntax_m_coded_sub_block),
        .m_scan_position(unused_syntax_scan_position),
        .m_group_scan_position(unused_syntax_group_position),
        .m_coefficient_index(unused_syntax_coefficient_index),
        .block_done(syntax_block_done),
        .any_nonzero(unused_syntax_any_nonzero),
        .last_nonzero_scan_position(unused_syntax_last_position),
        .significant_group_flags(unused_syntax_group_flags),
        .busy(unused_syntax_busy),
        .input_error(syntax_input_error)
    );

    hevc_coefficient_context_map context_map (
        .s_bypass(syntax_m_bypass),
        .s_source(syntax_m_source),
        .s_level_kind(syntax_m_level_kind),
        .s_context_index(syntax_m_context_index),
        .s_last_axis_y(syntax_m_last_axis_y),
        .s_significance_coded_sub_block(syntax_m_coded_sub_block),
        .m_cabac_kind(mapped_cabac_kind),
        .m_context_address(mapped_context_address),
        .m_context_valid(mapped_context_valid)
    );

    hevc_ctu64_syntax_scheduler scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .ctu_start_valid(ctu_start_valid && slice_active),
        .ctu_start_ready(scheduler_ctu_start_ready),
        .ctu_x(ctu_x),
        .ctu_last_in_slice(ctu_last_in_slice),
        .cu_valid(cu_valid && slice_active),
        .cu_ready(scheduler_cu_ready),
        .cu_luma_mode_dc(cu_luma_mode_dc),
        .cu_luma_cbf(cu_luma_cbf),
        .coefficient_valid(syntax_m_valid && mapped_context_valid),
        .coefficient_ready(scheduler_coefficient_ready),
        .coefficient_kind(mapped_cabac_kind),
        .coefficient_bin(syntax_m_bin),
        .coefficient_context_address(mapped_context_address),
        .coefficient_block_done(syntax_block_done),
        .m_valid(scheduler_m_valid),
        .m_ready(scheduler_m_ready),
        .m_kind(scheduler_m_kind),
        .m_bin(scheduler_m_bin),
        .m_context_address(scheduler_m_context_address),
        .m_last(unused_scheduler_m_last),
        .ctu_done(scheduler_ctu_done),
        .slice_termination(unused_scheduler_slice_termination),
        .protocol_error(scheduler_protocol_error),
        .busy(scheduler_busy)
    );

    hevc_cabac_encoder cabac (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cabac_cfg_valid),
        .cfg_ready(cabac_cfg_ready),
        .cfg_context_address(cabac_cfg_context_address),
        .cfg_state_index(cabac_cfg_state_index),
        .cfg_mps(cabac_cfg_mps),
        .start_valid(cabac_start_valid),
        .start_ready(cabac_start_ready),
        .s_valid(scheduler_m_valid && slice_active),
        .s_ready(cabac_s_ready),
        .s_kind(scheduler_m_kind),
        .s_bin(scheduler_m_bin),
        .s_context_address(scheduler_m_context_address),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_byte(m_byte),
        .m_last(m_last),
        .context_update_valid(unused_context_update_valid),
        .context_update_address(unused_context_update_address),
        .context_update_state_index(unused_context_update_state),
        .context_update_mps(unused_context_update_mps),
        .slice_done(slice_done),
        .protocol_error(cabac_protocol_error),
        .busy(cabac_busy)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slice_active <= 1'b0;
            outstanding_blocks <= 2'd0;
            input_count <= 8'd0;
            wrapper_error <= 1'b0;
        end else begin
            case ({coefficient_complete, syntax_block_done})
                2'b10: outstanding_blocks <= outstanding_blocks + 1'b1;
                2'b01: begin
                    if (outstanding_blocks != 0) begin
                        outstanding_blocks <= outstanding_blocks - 1'b1;
                    end else begin
                        wrapper_error <= 1'b1;
                    end
                end
                default: outstanding_blocks <= outstanding_blocks;
            endcase

            if (coefficient_fire) begin
                input_count <= coefficient_complete ?
                    8'd0 : input_count + 1'b1;
            end

            if (slice_start_fire) begin
                slice_active <= 1'b1;
                wrapper_error <= 1'b0;
            end
            if (final_terminate_fire) begin
                slice_active <= 1'b0;
                if ((outstanding_blocks != 0) || (input_count != 0)) begin
                    wrapper_error <= 1'b1;
                end
            end
            if (syntax_fire && !mapped_context_valid) begin
                wrapper_error <= 1'b1;
            end
            if (coefficient_complete && (outstanding_blocks == 2)) begin
                wrapper_error <= 1'b1;
            end
        end
    end
endmodule
