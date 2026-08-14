module hevc_coefficient_cabac16 (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               cfg_valid,
    output logic               cfg_ready,
    input  logic [7:0]         cfg_context_address,
    input  logic [5:0]         cfg_state_index,
    input  logic               cfg_mps,

    input  logic               slice_start_valid,
    output logic               slice_start_ready,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [7:0]         s_raster_address,
    input  logic signed [15:0] s_coefficient,
    input  logic               s_block_last,

    input  logic               slice_finish_valid,
    output logic               slice_finish_ready,

    output logic               m_valid,
    input  logic               m_ready,
    output logic [7:0]         m_byte,
    output logic               m_last,

    output logic               block_done,
    output logic               slice_done,
    output logic               protocol_error,
    output logic               busy
);
    localparam logic [1:0] CABAC_TERMINATE = 2'd2;

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

    logic cabac_s_valid;
    logic cabac_s_ready;
    logic [1:0] cabac_s_kind;
    logic cabac_s_bin;
    logic [7:0] cabac_s_context_address;
    logic cabac_protocol_error;
    logic cabac_busy;
    logic unused_context_update_valid;
    logic [7:0] unused_context_update_address;
    logic [5:0] unused_context_update_state;
    logic unused_context_update_mps;

    wire coefficient_fire = s_valid && s_ready;
    wire coefficient_complete = coefficient_fire &&
        (s_block_last || (input_count == 8'hff));
    wire syntax_fire = syntax_m_valid && syntax_m_ready;
    wire slice_start_fire = slice_start_valid && slice_start_ready;
    wire finish_eligible = slice_active &&
        (outstanding_blocks == 0) && (input_count == 0) &&
        !syntax_m_valid;
    wire slice_finish_fire = slice_finish_valid && slice_finish_ready;

    assign s_ready = slice_active && syntax_s_ready;
    assign syntax_m_ready = slice_active && cabac_s_ready;
    assign slice_finish_ready = finish_eligible && cabac_s_ready;

    assign cabac_s_valid = syntax_m_valid ||
        (slice_finish_valid && finish_eligible);
    assign cabac_s_kind = syntax_m_valid ?
        mapped_cabac_kind : CABAC_TERMINATE;
    assign cabac_s_bin = syntax_m_valid ? syntax_m_bin : 1'b1;
    assign cabac_s_context_address = syntax_m_valid ?
        mapped_context_address : 8'd0;

    assign block_done = syntax_block_done;
    assign protocol_error = wrapper_error || syntax_input_error ||
        cabac_protocol_error;
    assign busy = slice_active || cabac_busy ||
        (outstanding_blocks != 0) || (input_count != 0);

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

    hevc_cabac_encoder cabac (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .cfg_context_address(cfg_context_address),
        .cfg_state_index(cfg_state_index),
        .cfg_mps(cfg_mps),
        .start_valid(slice_start_valid),
        .start_ready(slice_start_ready),
        .s_valid(cabac_s_valid),
        .s_ready(cabac_s_ready),
        .s_kind(cabac_s_kind),
        .s_bin(cabac_s_bin),
        .s_context_address(cabac_s_context_address),
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
            if (slice_finish_fire) begin
                slice_active <= 1'b0;
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
