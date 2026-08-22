module receiver_base_intra_reconstruct #(
    parameter integer CTU_COUNT = 80
) (
    input  logic         clk,
    input  logic         rst_n,

    // A block command is observed several cycles before its first IDCT
    // sample.  Use that gap to register the CTU-wide DC predictors and keep
    // the residual-to-RAM path short.
    input  logic         block_start_valid,
    input  logic [6:0]   block_start_ctu_index,
    input  logic [2:0]   block_start_block_index,
    input  logic [1:0]   block_start_mode,
    input  logic [15:0]  block_start_frame_id,
    input  logic [7:0]   block_start_stripe_id,
    output logic         block_start_ready,

    input  logic         pixel_valid,
    output logic         pixel_ready,
    input  logic [5:0]   pixel_index,
    input  logic signed [15:0] pixel_residual,
    input  logic [6:0]   pixel_ctu_index,
    input  logic [2:0]   pixel_block_index,
    input  logic [1:0]   pixel_plane,
    input  logic [1:0]   pixel_mode,

    output logic         write_valid,
    input  logic         write_ready,
    output logic         write_start,
    output logic         write_last,
    output logic [15:0]  write_frame_id,
    output logic [7:0]   write_stripe_id,
    output logic [1:0]   write_plane,
    output logic [14:0]  write_address,
    output logic [7:0]   write_data,
    output logic         mode_error
);
    localparam logic [1:0] INTRA_DC         = 2'd0;
    localparam logic [1:0] INTRA_HORIZONTAL = 2'd2;

    logic [7:0] luma_left [0:15];
    logic [7:0] cb_left [0:7];
    logic [7:0] cr_left [0:7];
    logic [7:0] luma_dc, cb_dc, cr_dc;
    logic [15:0] active_frame_id;
    logic [7:0] active_stripe_id;
    logic reference_pending;
    logic [1:0] write_reference_plane;
    logic [3:0] write_reference_row;

    // Explicit balanced trees avoid a 16-input serial adder on the command
    // path.  These sums terminate in DC registers before any pixel arrives.
    logic [8:0] luma_sum2 [0:7];
    logic [9:0] luma_sum4 [0:3];
    logic [10:0] luma_sum8 [0:1];
    logic [11:0] luma_sum16;
    logic [8:0] cb_sum2 [0:3], cr_sum2 [0:3];
    logic [9:0] cb_sum4 [0:1], cr_sum4 [0:1];
    logic [10:0] cb_sum8, cr_sum8;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [7:0] rounded_dc16(input logic [11:0] sum);
        logic [11:0] rounded;
        begin
            rounded = sum + 12'd8;
            rounded_dc16 = rounded[11:4];
        end
    endfunction
    function automatic logic [7:0] rounded_dc8(input logic [10:0] sum);
        logic [10:0] rounded;
        begin
            rounded = sum + 11'd4;
            rounded_dc8 = rounded[10:3];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    integer sum_index;
    always_comb begin
        for (sum_index = 0; sum_index < 8; sum_index = sum_index + 1)
            luma_sum2[sum_index] = {1'b0, luma_left[sum_index * 2]}
                                  + {1'b0, luma_left[sum_index * 2 + 1]};
        for (sum_index = 0; sum_index < 4; sum_index = sum_index + 1) begin
            luma_sum4[sum_index] = {1'b0, luma_sum2[sum_index * 2]}
                                  + {1'b0, luma_sum2[sum_index * 2 + 1]};
            cb_sum2[sum_index] = {1'b0, cb_left[sum_index * 2]}
                               + {1'b0, cb_left[sum_index * 2 + 1]};
            cr_sum2[sum_index] = {1'b0, cr_left[sum_index * 2]}
                               + {1'b0, cr_left[sum_index * 2 + 1]};
        end
        for (sum_index = 0; sum_index < 2; sum_index = sum_index + 1) begin
            luma_sum8[sum_index] = {1'b0, luma_sum4[sum_index * 2]}
                                  + {1'b0, luma_sum4[sum_index * 2 + 1]};
            cb_sum4[sum_index] = {1'b0, cb_sum2[sum_index * 2]}
                               + {1'b0, cb_sum2[sum_index * 2 + 1]};
            cr_sum4[sum_index] = {1'b0, cr_sum2[sum_index * 2]}
                               + {1'b0, cr_sum2[sum_index * 2 + 1]};
        end
        luma_sum16 = {1'b0, luma_sum8[0]} + {1'b0, luma_sum8[1]};
        cb_sum8 = {1'b0, cb_sum4[0]} + {1'b0, cb_sum4[1]};
        cr_sum8 = {1'b0, cr_sum4[0]} + {1'b0, cr_sum4[1]};
    end

    wire output_advance = !write_valid || write_ready;
    assign pixel_ready = output_advance;
    assign block_start_ready = !reference_pending;
    logic [3:0] input_luma_row;
    logic [2:0] input_chroma_row;
    logic [7:0] input_prediction;
    logic signed [16:0] reconstructed_sum;
    logic [7:0] reconstructed_sample;
    logic [14:0] input_write_address;

    always_comb begin
        input_luma_row = {pixel_block_index[1], pixel_index[5:3]};
        input_chroma_row = pixel_index[5:3];

        if (pixel_mode == INTRA_HORIZONTAL
            && (pixel_ctu_index != 0)) begin
            case (pixel_plane)
                2'd0: input_prediction = luma_left[input_luma_row];
                2'd1: input_prediction = cb_left[input_chroma_row];
                default: input_prediction = cr_left[input_chroma_row];
            endcase
        end else begin
            case (pixel_plane)
                2'd0: input_prediction = luma_dc;
                2'd1: input_prediction = cb_dc;
                default: input_prediction = cr_dc;
            endcase
        end

        reconstructed_sum = $signed({9'd0, input_prediction})
                          + $signed({pixel_residual[15], pixel_residual});
        if (reconstructed_sum < 0)
            reconstructed_sample = 8'd0;
        else if (reconstructed_sum > 17'sd255)
            reconstructed_sample = 8'd255;
        else
            reconstructed_sample = reconstructed_sum[7:0];

        if (pixel_plane == 0) begin
            // local row * 1280 + CTU * 16 + sub-block * 8 + column
            input_write_address = {1'b0, input_luma_row, 10'd0}
                                + {3'd0, input_luma_row, 8'd0}
                                + {4'd0, pixel_ctu_index, 4'd0}
                                + {11'd0, pixel_block_index[0], 3'd0}
                                + {12'd0, pixel_index[2:0]};
        end else begin
            // local row * 640 + CTU * 8 + column
            input_write_address = {3'd0, input_chroma_row, 9'd0}
                                + {5'd0, input_chroma_row, 7'd0}
                                + {5'd0, pixel_ctu_index, 3'd0}
                                + {12'd0, pixel_index[2:0]};
        end
    end

    integer reference_index;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            luma_dc <= 8'd128;
            cb_dc <= 8'd128;
            cr_dc <= 8'd128;
            active_frame_id <= 16'd0;
            active_stripe_id <= 8'd0;
            write_valid <= 1'b0;
            write_start <= 1'b0;
            write_last <= 1'b0;
            write_frame_id <= 16'd0;
            write_stripe_id <= 8'd0;
            write_plane <= 2'd0;
            write_address <= 15'd0;
            write_data <= 8'd0;
            reference_pending <= 1'b0;
            write_reference_plane <= 2'd0;
            write_reference_row <= 4'd0;
            mode_error <= 1'b0;
            for (reference_index = 0; reference_index < 16;
                 reference_index = reference_index + 1)
                luma_left[reference_index] <= 8'd128;
            for (reference_index = 0; reference_index < 8;
                 reference_index = reference_index + 1) begin
                cb_left[reference_index] <= 8'd128;
                cr_left[reference_index] <= 8'd128;
            end
        end else begin
            // Reference feedback is deliberately one registered step after
            // reconstruction. The command gate holds the next block for this
            // one cycle when its right edge was just produced.
            if (reference_pending) begin
                case (write_reference_plane)
                    2'd0: luma_left[write_reference_row] <= write_data;
                    2'd1: cb_left[write_reference_row[2:0]] <= write_data;
                    default: cr_left[write_reference_row[2:0]] <= write_data;
                endcase
                reference_pending <= 1'b0;
            end

            if (block_start_valid) begin
                if ((block_start_mode != INTRA_DC)
                    && (block_start_mode != INTRA_HORIZONTAL))
                    mode_error <= 1'b1;
                if (block_start_block_index == 0) begin
                    active_frame_id <= block_start_frame_id;
                    active_stripe_id <= block_start_stripe_id;
                    if (block_start_ctu_index == 0) begin
                        luma_dc <= 8'd128;
                        cb_dc <= 8'd128;
                        cr_dc <= 8'd128;
                    end else begin
                        luma_dc <= rounded_dc16(luma_sum16);
                        cb_dc <= rounded_dc8(cb_sum8);
                        cr_dc <= rounded_dc8(cr_sum8);
                    end
                end
            end

            if (output_advance) begin
                write_valid <= pixel_valid;
                if (pixel_valid) begin
                    write_start <= (pixel_ctu_index == 0)
                                && (pixel_block_index == 0)
                                && (pixel_index == 0);
                    write_last <= (pixel_ctu_index == 7'(CTU_COUNT - 1))
                               && (pixel_block_index == 3'd5)
                               && (pixel_index == 6'd63);
                    write_frame_id <= active_frame_id;
                    write_stripe_id <= active_stripe_id;
                    write_plane <= pixel_plane;
                    write_address <= input_write_address;
                    write_data <= reconstructed_sample;
                    write_reference_plane <= pixel_plane;
                    write_reference_row <= (pixel_plane == 0)
                                         ? input_luma_row
                                         : {1'b0, input_chroma_row};
                    // Store only the right edge of the completed CTU. It is
                    // the sole reference needed by the next CTU in a 16-line
                    // independently decoded stripe.
                    reference_pending <= (pixel_index[2:0] == 3'd7)
                                      && ((pixel_plane != 0)
                                          || pixel_block_index[0]);
                end
            end
        end
    end
endmodule
