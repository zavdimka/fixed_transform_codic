module receiver_bounded_sparse_iht8 #(
    parameter logic [5:0] MAX_LUMA_AC = 6'd12,
    parameter logic [5:0] MAX_CHROMA_AC = 6'd6
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         load_start_valid,
    output logic         load_start_ready,
    input  logic [6:0]   load_ctu_index,
    input  logic [2:0]   load_block_index,
    input  logic [1:0]   load_plane,
    input  logic [1:0]   load_mode,
    input  logic [2:0]   load_quant_shift,
    input  logic         load_coeff_valid,
    output logic         load_coeff_ready,
    input  logic [5:0]   load_coeff_address,
    input  logic signed [11:0] load_coeff_data,
    input  logic         load_commit_valid,
    output logic         load_commit_ready,
    input  logic         load_abort,

    output logic         pixel_valid,
    input  logic         pixel_ready,
    output logic [5:0]   pixel_index,
    output logic signed [15:0] pixel_residual,
    output logic         pixel_last,
    output logic [6:0]   pixel_ctu_index,
    output logic [2:0]   pixel_block_index,
    output logic [1:0]   pixel_plane,
    output logic [1:0]   pixel_mode,

    output logic         busy,
    output logic         limit_error,
    output logic         duplicate_error,
    output logic [31:0]  completed_block_count
);
    localparam logic [1:0] BANK_FREE = 2'd0;
    localparam logic [1:0] BANK_LOAD = 2'd1;
    localparam logic [1:0] BANK_READY = 2'd2;
    localparam logic [1:0] BANK_ACTIVE = 2'd3;
    localparam logic [1:0] RESULT_FREE = 2'd0;
    localparam logic [1:0] RESULT_FILL = 2'd1;
    localparam logic [1:0] RESULT_READY = 2'd2;
    localparam logic [1:0] RESULT_OUTPUT = 2'd3;
    localparam logic [1:0] COMPUTE_IDLE = 2'd0;
    localparam logic [1:0] COMPUTE_PASS1 = 2'd1;
    localparam logic [1:0] COMPUTE_PASS2 = 2'd2;

    logic signed [11:0] coefficient_bank [0:1][0:63];
    logic [63:0] coefficient_valid [0:1];
    logic [1:0] coefficient_state [0:1];
    logic [6:0] coefficient_ctu [0:1];
    logic [2:0] coefficient_block [0:1];
    logic [1:0] coefficient_plane [0:1];
    logic [1:0] coefficient_mode [0:1];
    logic [2:0] coefficient_quant_shift [0:1];
    logic [5:0] coefficient_ac_count [0:1];
    // One coefficient bank is sufficient: it is released before the 64-cycle
    // result drain starts, so loading the next bounded block overlaps output.
    // Keeping this selection constant also avoids a high-fanout bank-select CE.
    wire coefficient_write_bank = 1'b0;
    wire coefficient_read_bank = 1'b0;
    logic load_active;
    logic coefficient_pending;
    logic [5:0] coefficient_pending_address;
    logic signed [11:0] coefficient_pending_data;
    logic coefficient_write_pending;
    logic coefficient_write_accept;
    logic coefficient_write_is_ac;
    logic [7:0] coefficient_write_row_select;
    logic [7:0] coefficient_write_column_select;
    logic signed [11:0] coefficient_write_data;

    logic signed [23:0] intermediate [0:63];
    logic signed [15:0] result_bank [0:1][0:63];
    logic [1:0] result_state [0:1];
    logic [6:0] result_ctu [0:1];
    logic [2:0] result_block [0:1];
    logic [1:0] result_plane [0:1];
    logic [1:0] result_mode [0:1];
    logic result_write_bank, result_read_bank;

    logic [1:0] compute_state;
    logic compute_coefficient_bank, compute_result_bank;
    logic [3:0] compute_issue_index;
    logic prefetch_valid;
    logic [2:0] prefetch_row;
    logic [2:0] prefetch_quant_shift;
    logic [7:0] prefetch_coefficient_valid;
    logic signed [95:0] prefetch_coefficients;
    logic launch_valid;
    logic [3:0] launch_tag;
    logic signed [191:0] launch_values;
    wire transform_output_valid;
    wire [3:0] transform_output_tag;
    wire signed [191:0] transform_output_values;
    logic result_stage_valid;
    logic [2:0] result_stage_tag;
    logic result_stage_bank;
    logic signed [127:0] result_stage_values;

    logic output_active;
    logic output_bank;
    logic [5:0] output_index;
    logic output_buffer_valid;
    logic [5:0] output_buffer_index;
    logic signed [15:0] output_buffer_residual;
    logic [6:0] output_buffer_ctu_index;
    logic [2:0] output_buffer_block_index;
    logic [1:0] output_buffer_plane;
    logic [1:0] output_buffer_mode;

    wire selected_coefficient_free =
        coefficient_state[coefficient_write_bank] == BANK_FREE;
    wire selected_coefficient_ready =
        coefficient_state[coefficient_read_bank] == BANK_READY;
    wire selected_result_free = result_state[result_write_bank] == RESULT_FREE;
    wire selected_result_ready = result_state[result_read_bank] == RESULT_READY;
    wire start_fire = load_start_valid && load_start_ready;
    wire coefficient_fire = load_coeff_valid && load_coeff_ready;
    wire commit_fire = load_commit_valid && load_commit_ready;
    wire output_buffer_advance = !output_buffer_valid || pixel_ready;

    assign load_start_ready = !load_active && selected_coefficient_free;
    assign load_coeff_ready = load_active && !coefficient_pending;
    assign load_commit_ready = load_active && !coefficient_pending
                             && !coefficient_write_pending;
    assign pixel_valid = output_buffer_valid;
    assign pixel_index = output_buffer_index;
    assign pixel_last = output_buffer_index == 6'd63;
    assign pixel_residual = output_buffer_residual;
    assign pixel_ctu_index = output_buffer_ctu_index;
    assign pixel_block_index = output_buffer_block_index;
    assign pixel_plane = output_buffer_plane;
    assign pixel_mode = output_buffer_mode;
    assign busy = load_active
                || (coefficient_state[0] != BANK_FREE)
                || (coefficient_state[1] != BANK_FREE)
                || (result_state[0] != RESULT_FREE)
                || (result_state[1] != RESULT_FREE)
                || output_buffer_valid;

    function automatic logic [2:0] weight_shift(input logic [5:0] address);
        logic [3:0] diagonal;
        begin
            diagonal = {1'b0, address[5:3]} + {1'b0, address[2:0]};
            if (diagonal <= 4'd1)
                weight_shift = 3'd0;
            else if (diagonal <= 4'd3)
                weight_shift = 3'd1;
            else if (diagonal <= 4'd5)
                weight_shift = 3'd2;
            else
                weight_shift = 3'd3;
        end
    endfunction

    function automatic logic [5:0] coefficient_limit(
        input logic [1:0] plane
    );
        begin
            if (plane == 2'd0)
                coefficient_limit = MAX_LUMA_AC;
            else
                coefficient_limit = MAX_CHROMA_AC;
        end
    endfunction

    function automatic logic signed [23:0] dequantize(
        input logic signed [11:0] value,
        input logic [5:0] address,
        input logic [2:0] quant_shift
    );
        logic [3:0] total_shift;
        logic signed [23:0] extended;
        begin
            total_shift = {1'b0, quant_shift}
                        + {1'b0, weight_shift(address)};
            extended = {{12{value[11]}}, value};
            case (total_shift)
                4'd0: dequantize = extended;
                4'd1: dequantize = extended <<< 1;
                4'd2: dequantize = extended <<< 2;
                4'd3: dequantize = extended <<< 3;
                4'd4: dequantize = extended <<< 4;
                4'd5: dequantize = extended <<< 5;
                default: dequantize = extended <<< 6;
            endcase
        end
    endfunction

    function automatic logic signed [15:0] round_clip16(
        input logic signed [23:0] value
    );
        logic signed [23:0] rounded;
        begin
            rounded = (value + 24'sd32) >>> 6;
            if (rounded > 24'sd32767)
                round_clip16 = 16'sd32767;
            else if (rounded < -24'sd32768)
                round_clip16 = -16'sd32768;
            else
                round_clip16 = rounded[15:0];
        end
    endfunction

    receiver_iht8_1d_pipeline transform_1d (
        .clk(clk), .rst_n(rst_n),
        .input_valid(launch_valid), .input_tag(launch_tag),
        .input_values(launch_values),
        .output_valid(transform_output_valid),
        .output_tag(transform_output_tag),
        .output_values(transform_output_values)
    );

    integer bank_index;
    integer value_index;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            coefficient_state[0] <= BANK_FREE;
            coefficient_state[1] <= BANK_FREE;
            result_state[0] <= RESULT_FREE;
            result_state[1] <= RESULT_FREE;
            result_write_bank <= 1'b0;
            result_read_bank <= 1'b0;
            load_active <= 1'b0;
            coefficient_pending <= 1'b0;
            coefficient_pending_address <= 6'd0;
            coefficient_pending_data <= 12'sd0;
            coefficient_write_pending <= 1'b0;
            coefficient_write_accept <= 1'b0;
            coefficient_write_is_ac <= 1'b0;
            coefficient_write_row_select <= 8'd0;
            coefficient_write_column_select <= 8'd0;
            coefficient_write_data <= 12'sd0;
            compute_state <= COMPUTE_IDLE;
            compute_coefficient_bank <= 1'b0;
            compute_result_bank <= 1'b0;
            compute_issue_index <= 4'd0;
            prefetch_valid <= 1'b0;
            prefetch_row <= 3'd0;
            prefetch_quant_shift <= 3'd0;
            prefetch_coefficient_valid <= 8'd0;
            prefetch_coefficients <= '0;
            launch_valid <= 1'b0;
            launch_tag <= 4'd0;
            launch_values <= '0;
            result_stage_valid <= 1'b0;
            result_stage_tag <= 3'd0;
            result_stage_bank <= 1'b0;
            result_stage_values <= '0;
            output_active <= 1'b0;
            output_bank <= 1'b0;
            output_index <= 6'd0;
            output_buffer_valid <= 1'b0;
            output_buffer_index <= 6'd0;
            output_buffer_residual <= 16'sd0;
            output_buffer_ctu_index <= 7'd0;
            output_buffer_block_index <= 3'd0;
            output_buffer_plane <= 2'd0;
            output_buffer_mode <= 2'd0;
            limit_error <= 1'b0;
            duplicate_error <= 1'b0;
            completed_block_count <= 32'd0;
            for (bank_index = 0; bank_index < 2; bank_index = bank_index + 1) begin
                coefficient_valid[bank_index] <= 64'd0;
                coefficient_ctu[bank_index] <= 7'd0;
                coefficient_block[bank_index] <= 3'd0;
                coefficient_plane[bank_index] <= 2'd0;
                coefficient_mode[bank_index] <= 2'd0;
                coefficient_quant_shift[bank_index] <= 3'd0;
                coefficient_ac_count[bank_index] <= 6'd0;
                result_ctu[bank_index] <= 7'd0;
                result_block[bank_index] <= 3'd0;
                result_plane[bank_index] <= 2'd0;
                result_mode[bank_index] <= 2'd0;
            end
        end else begin
            prefetch_valid <= 1'b0;
            launch_valid <= 1'b0;
            result_stage_valid <= 1'b0;

            if (start_fire) begin
                load_active <= 1'b1;
                coefficient_state[coefficient_write_bank] <= BANK_LOAD;
                coefficient_valid[coefficient_write_bank] <= 64'd0;
                coefficient_ctu[coefficient_write_bank] <= load_ctu_index;
                coefficient_block[coefficient_write_bank] <= load_block_index;
                coefficient_plane[coefficient_write_bank] <= load_plane;
                coefficient_mode[coefficient_write_bank] <= load_mode;
                coefficient_quant_shift[coefficient_write_bank]
                    <= load_quant_shift;
                coefficient_ac_count[coefficient_write_bank] <= 6'd0;
            end

            if (coefficient_fire) begin
                coefficient_pending <= 1'b1;
                coefficient_pending_address <= load_coeff_address;
                coefficient_pending_data <= load_coeff_data;

            end

            if (coefficient_write_pending) begin
                coefficient_write_pending <= 1'b0;
                if (coefficient_write_accept) begin
                    for (bank_index = 0; bank_index < 8;
                         bank_index = bank_index + 1) begin
                        for (value_index = 0; value_index < 8;
                             value_index = value_index + 1) begin
                            if (coefficient_write_row_select[bank_index]
                                && coefficient_write_column_select[value_index]) begin
                                coefficient_bank[0][bank_index*8 + value_index]
                                    <= coefficient_write_data;
                                coefficient_valid[0][bank_index*8 + value_index]
                                    <= 1'b1;
                            end
                        end
                    end
                    if (coefficient_write_is_ac)
                        coefficient_ac_count[coefficient_write_bank]
                            <= coefficient_ac_count[coefficient_write_bank]
                             + 1'b1;
                end
            end

            if (coefficient_pending && !(load_abort && load_active)) begin
                coefficient_pending <= 1'b0;
                coefficient_write_pending <= 1'b1;
                coefficient_write_data <= coefficient_pending_data;
                coefficient_write_is_ac
                    <= coefficient_pending_address != 0;
                coefficient_write_row_select
                    <= 8'b0000_0001 << coefficient_pending_address[5:3];
                coefficient_write_column_select
                    <= 8'b0000_0001 << coefficient_pending_address[2:0];
                if (coefficient_valid[coefficient_write_bank]
                                     [coefficient_pending_address]) begin
                    coefficient_write_accept <= 1'b0;
                    duplicate_error <= 1'b1;
                end else if ((coefficient_pending_address != 0)
                    && (coefficient_ac_count[coefficient_write_bank]
                        >= coefficient_limit(
                            coefficient_plane[coefficient_write_bank]))) begin
                    coefficient_write_accept <= 1'b0;
                    limit_error <= 1'b1;
                end else begin
                    coefficient_write_accept <= 1'b1;
                end
            end

            if (load_abort && load_active) begin
                coefficient_state[coefficient_write_bank] <= BANK_FREE;
                coefficient_valid[coefficient_write_bank] <= 64'd0;
                load_active <= 1'b0;
                coefficient_pending <= 1'b0;
                coefficient_write_pending <= 1'b0;
            end else if (commit_fire) begin
                coefficient_state[coefficient_write_bank] <= BANK_READY;
                load_active <= 1'b0;
            end

            if ((compute_state == COMPUTE_IDLE)
                && selected_coefficient_ready && selected_result_free) begin
                compute_coefficient_bank <= coefficient_read_bank;
                compute_result_bank <= result_write_bank;
                coefficient_state[coefficient_read_bank] <= BANK_ACTIVE;
                result_state[result_write_bank] <= RESULT_FILL;
                result_ctu[result_write_bank]
                    <= coefficient_ctu[coefficient_read_bank];
                result_block[result_write_bank]
                    <= coefficient_block[coefficient_read_bank];
                result_plane[result_write_bank]
                    <= coefficient_plane[coefficient_read_bank];
                result_mode[result_write_bank]
                    <= coefficient_mode[coefficient_read_bank];
                compute_issue_index <= 4'd0;
                compute_state <= COMPUTE_PASS1;
            end else if ((compute_state == COMPUTE_PASS1)
                         && (compute_issue_index < 8)) begin
                prefetch_valid <= 1'b1;
                prefetch_row <= compute_issue_index[2:0];
                prefetch_quant_shift
                    <= coefficient_quant_shift[compute_coefficient_bank];
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1) begin
                    prefetch_coefficient_valid[value_index]
                        <= coefficient_valid[compute_coefficient_bank]
                                            [{compute_issue_index[2:0],
                                              value_index[2:0]}];
                    prefetch_coefficients[value_index*12 +: 12]
                        <= coefficient_bank[compute_coefficient_bank]
                                           [{compute_issue_index[2:0],
                                             value_index[2:0]}];
                end
                compute_issue_index <= compute_issue_index + 1'b1;
            end else if ((compute_state == COMPUTE_PASS2)
                         && (compute_issue_index < 8)) begin
                launch_valid <= 1'b1;
                launch_tag <= {1'b1, compute_issue_index[2:0]};
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1)
                    launch_values[value_index*24 +: 24]
                        <= intermediate[{value_index[2:0],
                                         compute_issue_index[2:0]}];
                compute_issue_index <= compute_issue_index + 1'b1;
            end

            if (prefetch_valid) begin
                launch_valid <= 1'b1;
                launch_tag <= {1'b0, prefetch_row};
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1) begin
                    if (prefetch_coefficient_valid[value_index])
                        launch_values[value_index*24 +: 24]
                            <= dequantize(
                                prefetch_coefficients[value_index*12 +: 12],
                                {prefetch_row, value_index[2:0]},
                                prefetch_quant_shift
                            );
                    else
                        launch_values[value_index*24 +: 24] <= 24'sd0;
                end
            end

            if (transform_output_valid && !transform_output_tag[3]) begin
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1)
                    intermediate[{transform_output_tag[2:0],
                                  value_index[2:0]}]
                        <= $signed(transform_output_values[
                            value_index*24 +: 24]);
                if (transform_output_tag[2:0] == 3'd7) begin
                    compute_issue_index <= 4'd0;
                    compute_state <= COMPUTE_PASS2;
                end
            end

            if (transform_output_valid && transform_output_tag[3]) begin
                result_stage_valid <= 1'b1;
                result_stage_tag <= transform_output_tag[2:0];
                result_stage_bank <= compute_result_bank;
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1)
                    result_stage_values[value_index*16 +: 16]
                        <= round_clip16($signed(transform_output_values[
                            value_index*24 +: 24]));
            end

            if (result_stage_valid) begin
                for (value_index = 0; value_index < 8;
                     value_index = value_index + 1)
                    result_bank[result_stage_bank]
                               [{value_index[2:0], result_stage_tag}]
                        <= $signed(result_stage_values[
                            value_index*16 +: 16]);
                if (result_stage_tag == 3'd7) begin
                    result_state[result_stage_bank] <= RESULT_READY;
                    coefficient_state[compute_coefficient_bank] <= BANK_FREE;
                    coefficient_valid[compute_coefficient_bank] <= 64'd0;
                    result_write_bank <= ~result_write_bank;
                    compute_state <= COMPUTE_IDLE;
                end
            end

            if (!output_active && selected_result_ready) begin
                output_active <= 1'b1;
                output_bank <= result_read_bank;
                output_index <= 6'd0;
                result_state[result_read_bank] <= RESULT_OUTPUT;
            end

            if (output_buffer_advance) begin
                output_buffer_valid <= output_active;
                if (output_active) begin
                    output_buffer_index <= output_index;
                    output_buffer_residual
                        <= result_bank[output_bank][output_index];
                    output_buffer_ctu_index <= result_ctu[output_bank];
                    output_buffer_block_index <= result_block[output_bank];
                    output_buffer_plane <= result_plane[output_bank];
                    output_buffer_mode <= result_mode[output_bank];
                    if (output_index == 6'd63) begin
                        output_index <= 6'd0;
                        result_state[output_bank] <= RESULT_FREE;
                        completed_block_count <= completed_block_count + 1'b1;
                        if (result_state[~output_bank] == RESULT_READY) begin
                            output_active <= 1'b1;
                            output_bank <= ~output_bank;
                            result_state[~output_bank] <= RESULT_OUTPUT;
                            result_read_bank <= ~output_bank;
                        end else begin
                            output_active <= 1'b0;
                            result_read_bank <= ~result_read_bank;
                        end
                    end else begin
                        output_index <= output_index + 1'b1;
                    end
                end
            end
        end
    end
endmodule
