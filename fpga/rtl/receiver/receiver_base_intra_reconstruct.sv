module receiver_base_intra_reconstruct #(
    parameter integer CTU_COUNT = 80
) (
    input  logic         clk,
    input  logic         rst_n,

    // Block commands arrive before their first IDCT sample.  The streaming
    // format uses neutral DC prediction and optional reconstructed left-edge
    // horizontal prediction.
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
    input  logic signed [15:0] pixel_reference_residual,
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
    logic [15:0] active_frame_id;
    logic [7:0] active_stripe_id;
    logic ctu_boundary_wait;
    logic reference_pending;
    logic [1:0] write_reference_plane;
    logic [3:0] write_reference_row;
    logic [7:0] write_reference_data;

    wire output_advance = !write_valid || write_ready;
    logic prediction_valid;
    logic [7:0] prediction_data;
    logic signed [15:0] prediction_residual;
    logic signed [15:0] prediction_reference_residual;
    logic [5:0] prediction_pixel_index;
    logic [6:0] prediction_ctu_index;
    logic [2:0] prediction_block_index;
    logic [1:0] prediction_plane, prediction_mode;
    logic [14:0] prediction_write_address;
    wire prediction_advance = !prediction_valid || output_advance;
    assign pixel_ready = prediction_advance;
    // With the added prediction stage the transform can become idle one cycle
    // before its final sample is committed. Do not let the following block
    // snapshot DC references across that boundary.
    // The full IDCT accepts a following command before all 64 pixels of the
    // previous command have emerged. That overlap is safe inside a CTU, but
    // block 0 of the next CTU must wait for block 5's right-edge reference.
    assign block_start_ready = !reference_pending
                             && !(ctu_boundary_wait
                                  && (block_start_block_index == 0))
                             && !(prediction_valid
                                  && (prediction_pixel_index == 6'd63));
    logic [3:0] input_luma_row;
    logic [2:0] input_chroma_row;
    logic [7:0] input_prediction;
    logic signed [16:0] reconstructed_sum;
    logic [7:0] reconstructed_sample;
    logic signed [16:0] reference_sum;
    logic [7:0] reference_sample;
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
        end else
            // Mode 0 is an independently decodable neutral predictor.  The
            // camera encoder does not feed reconstructed CTU edges back into
            // its predictor, so deriving DC from the previous CTU here would
            // create accumulating decoder drift.
            input_prediction = 8'd128;

        reconstructed_sum = $signed({9'd0, prediction_data})
                          + $signed({prediction_residual[15],
                                     prediction_residual});
        if (reconstructed_sum < 0)
            reconstructed_sample = 8'd0;
        else if (reconstructed_sum > 17'sd255)
            reconstructed_sample = 8'd255;
        else
            reconstructed_sample = reconstructed_sum[7:0];

        reference_sum = $signed({9'd0, prediction_data})
                      + $signed({prediction_reference_residual[15],
                                 prediction_reference_residual});
        if (reference_sum < 0)
            reference_sample = 8'd0;
        else if (reference_sum > 17'sd255)
            reference_sample = 8'd255;
        else
            reference_sample = reference_sum[7:0];

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

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_frame_id <= 16'd0;
            active_stripe_id <= 8'd0;
            ctu_boundary_wait <= 1'b0;
            write_valid <= 1'b0;
            write_start <= 1'b0;
            write_last <= 1'b0;
            write_frame_id <= 16'd0;
            write_stripe_id <= 8'd0;
            write_plane <= 2'd0;
            write_address <= 15'd0;
            write_data <= 8'd0;
            reference_pending <= 1'b0;
            prediction_valid <= 1'b0;
            prediction_data <= 8'd0;
            prediction_residual <= 16'sd0;
            prediction_reference_residual <= 16'sd0;
            prediction_pixel_index <= 6'd0;
            prediction_ctu_index <= 7'd0;
            prediction_block_index <= 3'd0;
            prediction_plane <= 2'd0;
            prediction_mode <= 2'd0;
            prediction_write_address <= 15'd0;
            write_reference_plane <= 2'd0;
            write_reference_row <= 4'd0;
            write_reference_data <= 8'd0;
            mode_error <= 1'b0;
            // Reference arrays deliberately have no reset. CTU 0 uses the
            // fixed neutral predictor and writes every right-edge entry before
            // CTU 1 can consume horizontal mode. Resetting these 256 data bits
            // put the global reset net on the routed critical path.
        end else begin
            // Reference feedback is deliberately one registered step after
            // reconstruction. The command gate holds the next block for this
            // one cycle when its right edge was just produced.
            if (reference_pending) begin
                case (write_reference_plane)
                    2'd0: luma_left[write_reference_row] <= write_reference_data;
                    2'd1: cb_left[write_reference_row[2:0]] <= write_reference_data;
                    default: cr_left[write_reference_row[2:0]] <= write_reference_data;
                endcase
                reference_pending <= 1'b0;
            end

            if (block_start_valid) begin
                if (block_start_block_index == 3'd5)
                    ctu_boundary_wait <= 1'b1;
                if ((block_start_mode != INTRA_DC)
                    && (block_start_mode != INTRA_HORIZONTAL))
                    mode_error <= 1'b1;
                if (block_start_block_index == 0) begin
                    active_frame_id <= block_start_frame_id;
                    active_stripe_id <= block_start_stripe_id;
                end
            end

            if (prediction_advance) begin
                prediction_valid <= pixel_valid;
                if (pixel_valid) begin
                    prediction_data <= input_prediction;
                    prediction_residual <= pixel_residual;
                    prediction_reference_residual <=
                        pixel_reference_residual;
                    prediction_pixel_index <= pixel_index;
                    prediction_ctu_index <= pixel_ctu_index;
                    prediction_block_index <= pixel_block_index;
                    prediction_plane <= pixel_plane;
                    prediction_mode <= pixel_mode;
                    prediction_write_address <= input_write_address;
                end
            end

            if (output_advance) begin
                write_valid <= prediction_valid;
                if (prediction_valid) begin
                    if ((prediction_block_index == 3'd5)
                        && (prediction_pixel_index == 6'd63))
                        ctu_boundary_wait <= 1'b0;
                    write_start <= (prediction_ctu_index == 0)
                                && (prediction_block_index == 0)
                                && (prediction_pixel_index == 0);
                    write_last <=
                        (prediction_ctu_index == 7'(CTU_COUNT - 1))
                        && (prediction_block_index == 3'd5)
                        && (prediction_pixel_index == 6'd63);
                    write_frame_id <= active_frame_id;
                    write_stripe_id <= active_stripe_id;
                    write_plane <= prediction_plane;
                    write_address <= prediction_write_address;
                    write_data <= reconstructed_sample;
                    write_reference_plane <= prediction_plane;
                    write_reference_row <=
                        (prediction_plane == 0)
                        ? {prediction_block_index[1],
                           prediction_pixel_index[5:3]}
                        : {1'b0, prediction_pixel_index[5:3]};
                    write_reference_data <= reference_sample;
                    // Store only the right edge of the completed CTU. It is
                    // the sole reference needed by the next CTU in a 16-line
                    // independently decoded stripe.
                    reference_pending <=
                        (prediction_pixel_index[2:0] == 3'd7)
                        && ((prediction_plane != 0)
                            || prediction_block_index[0]);
                end
            end
        end
    end
endmodule
