module receiver_base_decode_pipeline #(
    parameter integer CTU_COUNT = 80,
    parameter bit ENABLE_ENHANCEMENT = 1'b1,
    parameter bit ENABLE_DIAGNOSTICS = 1'b1
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         record_valid,
    output logic         record_ready,
    input  logic [15:0]  display_frame_id,
    input  logic [7:0]   stripe_id,
    input  logic [7:0]   quality,
    input  logic [7:0]   fragment_index,
    input  logic [7:0]   fragment_count,
    input  logic [7:0]   record_flags,
    input  logic [15:0]  payload_length,
    input  logic [7:0]   payload_data,
    input  logic         payload_valid,
    output logic         payload_ready,
    input  logic         payload_last,

    input  logic         record_enhancement_available,
    input  logic         enhancement_event_valid,
    output logic         enhancement_event_ready,
    input  logic [1:0]   enhancement_event_kind,
    input  logic [6:0]   enhancement_event_ctu_index,
    input  logic [2:0]   enhancement_event_block_index,
    input  logic [1:0]   enhancement_event_plane,
    input  logic [5:0]   enhancement_event_scan_index,
    input  logic signed [11:0] enhancement_event_coefficient,
    input  logic [7:0]   enhancement_event_quality,
    input  logic [15:0]  enhancement_event_frame_id,
    input  logic [7:0]   enhancement_event_stripe_id,

    output logic         decoded_write_valid,
    input  logic         decoded_write_ready,
    output logic         decoded_write_start,
    output logic         decoded_write_last,
    output logic [15:0]  decoded_frame_id,
    output logic [7:0]   decoded_stripe_id,
    output logic [1:0]   decoded_plane,
    output logic [14:0]  decoded_address,
    output logic [7:0]   decoded_data,

    output logic [1:0]   block_fifo_level,
    output logic         transform_busy,
    output logic         saturation_error,
    output logic         prediction_mode_error,
    output logic [15:0]  residual_xor,
    output logic [31:0]  completed_stripe_count,
    output logic [31:0]  rejected_stripe_count,
    output logic [31:0]  syntax_error_count,
    output logic [31:0]  enhanced_block_count,
    output logic [31:0]  enhancement_fallback_block_count,
    output logic [31:0]  enhancement_late_stripe_count,
    output logic         enhancement_alignment_error
);
    logic block_valid, block_ready;
    logic [6:0] block_ctu_index;
    logic [2:0] block_index;
    logic [1:0] block_plane, block_mode;
    logic [7:0] block_quality;
    logic [15:0] block_frame_id;
    logic [7:0] block_stripe_id;
    logic [71:0] block_coefficients;
    logic stripe_done;
    logic [15:0] completed_frame_id;
    logic [7:0] completed_stripe_id, completed_quality;

    receiver_base_entropy_decoder #(.CTU_COUNT(CTU_COUNT)) entropy (
        .clk(clk), .rst_n(rst_n),
        .record_valid(record_valid), .record_ready(record_ready),
        .display_frame_id(display_frame_id), .stripe_id(stripe_id),
        .quality(quality), .fragment_index(fragment_index),
        .fragment_count(fragment_count), .record_flags(record_flags),
        .payload_length(payload_length), .payload_data(payload_data),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .payload_last(payload_last),
        .block_valid(block_valid), .block_ready(block_ready),
        .block_ctu_index(block_ctu_index), .block_index(block_index),
        .block_plane(block_plane), .block_mode(block_mode),
        .block_quality(block_quality), .block_frame_id(block_frame_id),
        .block_stripe_id(block_stripe_id),
        .block_coefficients(block_coefficients),
        .stripe_done(stripe_done), .stripe_frame_id(completed_frame_id),
        .completed_stripe_id(completed_stripe_id),
        .stripe_quality(completed_quality),
        .completed_stripe_count(completed_stripe_count),
        .rejected_stripe_count(rejected_stripe_count),
        .syntax_error_count(syntax_error_count)
    );

    logic transform_command_valid;
    logic [6:0] transform_ctu_index;
    logic [2:0] transform_block_index;
    logic [1:0] transform_plane, transform_mode;
    logic [7:0] transform_quality;
    logic [15:0] transform_frame_id;
    logic [7:0] transform_stripe_id;
    logic [71:0] transform_coefficients;
    logic reconstruction_block_start_ready;
    logic reconstruction_start_pending;
    logic [6:0] reconstruction_start_ctu_index;
    logic [2:0] reconstruction_start_block_index;
    logic [1:0] reconstruction_start_mode;
    logic [15:0] reconstruction_start_frame_id;
    logic [7:0] reconstruction_start_stripe_id;
    logic combiner_base_ready;
    wire transform_fifo_pop = transform_command_valid
                            && combiner_base_ready;

    receiver_base_block_fifo2 block_fifo (
        .clk(clk), .rst_n(rst_n),
        .s_valid(block_valid), .s_ready(block_ready),
        .s_ctu_index(block_ctu_index), .s_block_index(block_index),
        .s_plane(block_plane), .s_mode(block_mode),
        .s_quality(block_quality), .s_frame_id(block_frame_id),
        .s_stripe_id(block_stripe_id), .s_coefficients(block_coefficients),
        .m_valid(transform_command_valid), .m_ready(transform_fifo_pop),
        .m_ctu_index(transform_ctu_index),
        .m_block_index(transform_block_index), .m_plane(transform_plane),
        .m_mode(transform_mode), .m_quality(transform_quality),
        .m_frame_id(transform_frame_id), .m_stripe_id(transform_stripe_id),
        .m_coefficients(transform_coefficients), .level(block_fifo_level)
    );

    logic full_command_valid, full_command_ready;
    logic [6:0] full_command_ctu_index;
    logic [2:0] full_command_block_index;
    logic [1:0] full_command_plane, full_command_mode;
    logic [7:0] full_command_quality;
    logic [15:0] full_command_frame_id;
    logic [7:0] full_command_stripe_id;
    logic [767:0] full_command_coefficients;
    logic full_command_enhanced;
    logic load_start_valid, load_start_ready;
    logic [6:0] load_ctu_index;
    logic [2:0] load_block_index;
    logic [1:0] load_plane, load_mode;
    logic [7:0] load_quality;
    logic [15:0] load_frame_id;
    logic [7:0] load_stripe_id;
    logic load_coeff_valid, load_coeff_ready;
    logic [5:0] load_coeff_address;
    logic signed [11:0] load_coeff_data;
    logic load_base_valid, load_base_ready;
    logic [71:0] load_base_coefficients;
    logic load_base_plane;
    logic load_commit_valid, load_commit_ready;
    logic idct_load_commit_ready, load_abort;
    wire base_stripe_start_event = record_valid && record_ready
                                 && (fragment_index == 0);
    logic base_stripe_start;
    logic base_stripe_enhancement_available;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            base_stripe_start <= 1'b0;
            base_stripe_enhancement_available <= 1'b0;
        end else begin
            base_stripe_start <= base_stripe_start_event;
            if (base_stripe_start_event)
                base_stripe_enhancement_available <=
                    record_enhancement_available;
        end
    end
    wire full_command_pop = full_command_ready
                          && reconstruction_block_start_ready;

    generate if (ENABLE_ENHANCEMENT) begin : with_enhancement_combiner
    receiver_base_enhancement_stream_join #(
        .ENABLE_COUNTERS(ENABLE_DIAGNOSTICS)
    ) combiner (
        .clk(clk), .rst_n(rst_n),
        .stripe_start(base_stripe_start),
        .stripe_enhancement_available(base_stripe_enhancement_available),
        .base_valid(transform_command_valid),
        .base_ready(combiner_base_ready),
        .base_ctu_index(transform_ctu_index),
        .base_block_index(transform_block_index),
        .base_plane(transform_plane), .base_mode(transform_mode),
        .base_quality(transform_quality),
        .base_frame_id(transform_frame_id),
        .base_stripe_id(transform_stripe_id),
        .base_coefficients(transform_coefficients),
        .enhancement_event_valid(enhancement_event_valid),
        .enhancement_event_ready(enhancement_event_ready),
        .enhancement_event_kind(enhancement_event_kind),
        .enhancement_event_ctu_index(enhancement_event_ctu_index),
        .enhancement_event_block_index(enhancement_event_block_index),
        .enhancement_event_plane(enhancement_event_plane),
        .enhancement_event_scan_index(enhancement_event_scan_index),
        .enhancement_event_coefficient(enhancement_event_coefficient),
        .enhancement_event_quality(enhancement_event_quality),
        .enhancement_event_frame_id(enhancement_event_frame_id),
        .enhancement_event_stripe_id(enhancement_event_stripe_id),
        .load_start_valid(load_start_valid),
        .load_start_ready(load_start_ready),
        .load_ctu_index(load_ctu_index),
        .load_block_index(load_block_index),
        .load_plane(load_plane), .load_mode(load_mode),
        .load_quality(load_quality), .load_frame_id(load_frame_id),
        .load_stripe_id(load_stripe_id),
        .load_coeff_valid(load_coeff_valid),
        .load_coeff_ready(load_coeff_ready),
        .load_coeff_address(load_coeff_address),
        .load_coeff_data(load_coeff_data),
        .load_base_valid(load_base_valid),
        .load_base_ready(load_base_ready),
        .load_base_coefficients(load_base_coefficients),
        .load_base_plane(load_base_plane),
        .load_commit_valid(load_commit_valid),
        .load_commit_ready(load_commit_ready),
        .load_abort(load_abort),
        .enhanced_block_count(enhanced_block_count),
        .fallback_block_count(enhancement_fallback_block_count),
        .late_stripe_count(enhancement_late_stripe_count),
        .alignment_error(enhancement_alignment_error)
    );
    assign full_command_valid = 1'b0;
    assign full_command_ctu_index = 7'd0;
    assign full_command_block_index = 3'd0;
    assign full_command_plane = 2'd0;
    assign full_command_mode = 2'd0;
    assign full_command_quality = 8'd0;
    assign full_command_frame_id = 16'd0;
    assign full_command_stripe_id = 8'd0;
    assign full_command_coefficients = 768'd0;
    assign full_command_enhanced = 1'b0;
    end else begin : base_only_combiner
        // The base layer is already a complete prediction reference. Bypass
        // the 64-coefficient combiner in the 720p50 performance profile.
        assign combiner_base_ready = full_command_pop;
        assign enhancement_event_ready = 1'b1;
        assign full_command_valid = transform_command_valid;
        assign full_command_ctu_index = transform_ctu_index;
        assign full_command_block_index = transform_block_index;
        assign full_command_plane = transform_plane;
        assign full_command_mode = transform_mode;
        assign full_command_quality = transform_quality;
        assign full_command_frame_id = transform_frame_id;
        assign full_command_stripe_id = transform_stripe_id;
        assign full_command_coefficients = {696'd0, transform_coefficients};
        assign full_command_enhanced = 1'b0;
        assign enhanced_block_count = 32'd0;
        assign enhancement_fallback_block_count = 32'd0;
        assign enhancement_late_stripe_count = 32'd0;
        assign enhancement_alignment_error = 1'b0;
        assign load_start_valid = 1'b0;
        assign load_ctu_index = 7'd0;
        assign load_block_index = 3'd0;
        assign load_plane = 2'd0;
        assign load_mode = 2'd0;
        assign load_quality = 8'd0;
        assign load_frame_id = 16'd0;
        assign load_stripe_id = 8'd0;
        assign load_coeff_valid = 1'b0;
        assign load_coeff_address = 6'd0;
        assign load_coeff_data = 12'sd0;
        assign load_base_valid = 1'b0;
        assign load_base_coefficients = 72'd0;
        assign load_base_plane = 1'b0;
        assign load_commit_valid = 1'b0;
        assign load_abort = 1'b0;
    end endgenerate

    logic transform_pixel_valid, transform_pixel_ready;
    logic [5:0] transform_pixel_index;
    logic signed [15:0] transform_pixel_residual;
    logic signed [15:0] transform_pixel_reference_residual;
    logic transform_pixel_last;
    logic [6:0] transform_pixel_ctu_index;
    logic [2:0] transform_pixel_block_index;
    logic [1:0] transform_pixel_plane, transform_pixel_mode;
    logic transform_done, transform_saturated;
    logic bounded_coeff_valid, bounded_coeff_ready;
    logic [5:0] bounded_coeff_address;
    logic signed [11:0] bounded_coeff_data;
    logic [2:0] bounded_base_index;
    logic bounded_limit_error, bounded_duplicate_error;
    logic [31:0] bounded_completed_block_count;
    wire [2:0] bounded_base_last_index = (load_plane == 0)
        ? 3'd5 : 3'd2;
    wire bounded_coeff_fire = bounded_coeff_valid && bounded_coeff_ready;
    wire stream_commit_fire = load_commit_valid && load_commit_ready;
    wire transform_command_fire = ENABLE_ENHANCEMENT
        ? stream_commit_fire : (full_command_valid && full_command_pop);
    wire reconstruction_start_fire = reconstruction_start_pending
                                   && reconstruction_block_start_ready;
    wire reconstruction_queue_ready = !reconstruction_start_pending
                                    || reconstruction_block_start_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            reconstruction_start_pending <= 1'b0;
            reconstruction_start_ctu_index <= 7'd0;
            reconstruction_start_block_index <= 3'd0;
            reconstruction_start_mode <= 2'd0;
            reconstruction_start_frame_id <= 16'd0;
            reconstruction_start_stripe_id <= 8'd0;
        end else if (ENABLE_ENHANCEMENT) begin
            if (reconstruction_start_fire)
                reconstruction_start_pending <= 1'b0;
            if (stream_commit_fire) begin
                reconstruction_start_pending <= 1'b1;
                reconstruction_start_ctu_index <= load_ctu_index;
                reconstruction_start_block_index <= load_block_index;
                reconstruction_start_mode <= load_mode;
                reconstruction_start_frame_id <= load_frame_id;
                reconstruction_start_stripe_id <= load_stripe_id;
            end
        end
    end

    logic reconstruction_write_valid, reconstruction_write_ready;
    logic reconstruction_write_start, reconstruction_write_last;
    logic [15:0] reconstruction_frame_id;
    logic [7:0] reconstruction_stripe_id;
    logic [1:0] reconstruction_plane;
    logic [14:0] reconstruction_address;
    logic [7:0] reconstruction_data;

    logic write_fifo_start [0:3];
    logic write_fifo_last [0:3];
    logic [15:0] write_fifo_frame_id [0:3];
    logic [7:0] write_fifo_stripe_id [0:3];
    logic [1:0] write_fifo_plane [0:3];
    logic [14:0] write_fifo_address [0:3];
    logic [7:0] write_fifo_data [0:3];
    logic [1:0] write_fifo_write_pointer, write_fifo_read_pointer;
    logic [2:0] write_fifo_level;
    wire write_fifo_input_fire = reconstruction_write_valid
                               && reconstruction_write_ready;
    wire write_fifo_output_fire = decoded_write_valid
                                && decoded_write_ready;

    // Keep downstream FIFO occupancy off the IDCT clock-enable path. This
    // uses registered ready and one reserved slot, so occupancy cannot feed
    // reconstruction or IDCT clock enables in the same cycle.
   assign decoded_write_valid = (write_fifo_level != 0);
    assign decoded_write_start = write_fifo_start[write_fifo_read_pointer];
    assign decoded_write_last = write_fifo_last[write_fifo_read_pointer];
    assign decoded_frame_id = write_fifo_frame_id[write_fifo_read_pointer];
    assign decoded_stripe_id = write_fifo_stripe_id[write_fifo_read_pointer];
    assign decoded_plane = write_fifo_plane[write_fifo_read_pointer];
    assign decoded_address = write_fifo_address[write_fifo_read_pointer];
    assign decoded_data = write_fifo_data[write_fifo_read_pointer];

    generate if (ENABLE_ENHANCEMENT) begin : with_enhancement_transform
    assign bounded_coeff_valid = load_coeff_valid || load_base_valid;
    assign bounded_coeff_address = load_base_valid
        ? ((bounded_base_index == 0) ? 6'd0
        :  (bounded_base_index == 1) ? 6'd1
        :  (bounded_base_index == 2) ? 6'd8
        :  (bounded_base_index == 3) ? 6'd16
        :  (bounded_base_index == 4) ? 6'd9 : 6'd2)
        : load_coeff_address;
    assign bounded_coeff_data = load_base_valid
        ? $signed(load_base_coefficients[bounded_base_index*12 +: 12])
        : load_coeff_data;
    assign load_coeff_ready = bounded_coeff_ready && !load_base_valid;
    assign load_base_ready = load_base_valid && bounded_coeff_ready
                           && (bounded_base_index == bounded_base_last_index);

    always_ff @(posedge clk) begin
        if (!rst_n || load_abort)
            bounded_base_index <= 3'd0;
        else if (bounded_coeff_fire && load_base_valid) begin
            if (bounded_base_index == bounded_base_last_index)
                bounded_base_index <= 3'd0;
            else
                bounded_base_index <= bounded_base_index + 1'b1;
        end
    end

    receiver_bounded_sparse_iht8 inverse_transform (
        .clk(clk), .rst_n(rst_n),
        .load_start_valid(load_start_valid),
        .load_start_ready(load_start_ready),
        .load_ctu_index(load_ctu_index),
        .load_block_index(load_block_index),
        .load_plane(load_plane), .load_mode(load_mode),
        .load_quant_shift(load_quality[2:0]),
        .load_coeff_valid(bounded_coeff_valid),
        .load_coeff_ready(bounded_coeff_ready),
        .load_coeff_address(bounded_coeff_address),
        .load_coeff_data(bounded_coeff_data),
        .load_commit_valid(load_commit_valid
                           && reconstruction_queue_ready),
        .load_commit_ready(idct_load_commit_ready),
        .load_abort(load_abort),
        .pixel_valid(transform_pixel_valid),
        .pixel_ready(transform_pixel_ready),
        .pixel_index(transform_pixel_index),
        .pixel_residual(transform_pixel_residual),
        .pixel_last(transform_pixel_last),
        .pixel_ctu_index(transform_pixel_ctu_index),
        .pixel_block_index(transform_pixel_block_index),
        .pixel_plane(transform_pixel_plane),
        .pixel_mode(transform_pixel_mode),
        .busy(transform_busy),
        .limit_error(bounded_limit_error),
        .duplicate_error(bounded_duplicate_error),
        .completed_block_count(bounded_completed_block_count)
    );
    assign full_command_ready = 1'b0;
    assign transform_pixel_reference_residual = transform_pixel_residual;
    assign transform_done = transform_pixel_valid && transform_pixel_ready
                          && transform_pixel_last;
    assign transform_saturated = bounded_limit_error
                               || bounded_duplicate_error;
    assign load_commit_ready = idct_load_commit_ready
                             && reconstruction_queue_ready;
    end else begin : base_only_transform
        assign load_start_ready = 1'b0;
        assign load_coeff_ready = 1'b0;
        assign load_base_ready = 1'b0;
        assign load_commit_ready = 1'b0;
        assign idct_load_commit_ready = 1'b0;
        assign transform_pixel_reference_residual = transform_pixel_residual;

        receiver_sparse_base_idct8 inverse_transform (
            .clk(clk), .rst_n(rst_n),
            .command_valid(full_command_valid
                           && reconstruction_block_start_ready),
            .command_ready(full_command_ready),
            .command_ctu_index(full_command_ctu_index),
            .command_block_index(full_command_block_index),
            .command_plane(full_command_plane),
            .command_mode(full_command_mode),
            .command_quality(full_command_quality),
            .command_coefficients(transform_coefficients),
            .pixel_valid(transform_pixel_valid),
            .pixel_ready(transform_pixel_ready),
            .pixel_index(transform_pixel_index),
            .pixel_residual(transform_pixel_residual),
            .pixel_last(transform_pixel_last),
            .pixel_ctu_index(transform_pixel_ctu_index),
            .pixel_block_index(transform_pixel_block_index),
            .pixel_plane(transform_pixel_plane),
            .pixel_mode(transform_pixel_mode),
            .done(transform_done), .busy(transform_busy),
            .saturated(transform_saturated)
        );
    end endgenerate

    logic reconstruction_pixel_ready;
    wire transform_pixel_waits_for_start = ENABLE_ENHANCEMENT
        && reconstruction_start_pending && transform_pixel_valid
        && (transform_pixel_block_index == reconstruction_start_block_index);
    wire reconstruction_pixel_valid = transform_pixel_valid
                                      && !transform_pixel_waits_for_start;
    assign transform_pixel_ready = reconstruction_pixel_ready
                                && !transform_pixel_waits_for_start;

    receiver_base_intra_reconstruct #(.CTU_COUNT(CTU_COUNT)) reconstruction (
        .clk(clk), .rst_n(rst_n),
        .block_start_valid(ENABLE_ENHANCEMENT
            ? reconstruction_start_fire : transform_command_fire),
        .block_start_ctu_index(ENABLE_ENHANCEMENT
            ? reconstruction_start_ctu_index : full_command_ctu_index),
        .block_start_block_index(ENABLE_ENHANCEMENT
            ? reconstruction_start_block_index : full_command_block_index),
        .block_start_mode(ENABLE_ENHANCEMENT
            ? reconstruction_start_mode : full_command_mode),
        .block_start_frame_id(ENABLE_ENHANCEMENT
            ? reconstruction_start_frame_id : full_command_frame_id),
        .block_start_stripe_id(ENABLE_ENHANCEMENT
            ? reconstruction_start_stripe_id : full_command_stripe_id),
        .block_start_ready(reconstruction_block_start_ready),
        .pixel_valid(reconstruction_pixel_valid),
        .pixel_ready(reconstruction_pixel_ready),
        .pixel_index(transform_pixel_index),
        .pixel_residual(transform_pixel_residual),
        .pixel_reference_residual(transform_pixel_reference_residual),
        .pixel_ctu_index(transform_pixel_ctu_index),
        .pixel_block_index(transform_pixel_block_index),
        .pixel_plane(transform_pixel_plane),
        .pixel_mode(transform_pixel_mode),
        .write_valid(reconstruction_write_valid),
        .write_ready(reconstruction_write_ready),
        .write_start(reconstruction_write_start),
        .write_last(reconstruction_write_last),
        .write_frame_id(reconstruction_frame_id),
        .write_stripe_id(reconstruction_stripe_id),
        .write_plane(reconstruction_plane),
        .write_address(reconstruction_address),
        .write_data(reconstruction_data),
        .mode_error(prediction_mode_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_fifo_write_pointer <= 2'd0;
            write_fifo_read_pointer <= 2'd0;
            write_fifo_level <= 3'd0;
            reconstruction_write_ready <= 1'b1;
        end else begin
            // One reserved slot absorbs the extra cycle of registered ready.
            reconstruction_write_ready <= (write_fifo_level < 3'd3);
            case ({write_fifo_input_fire, write_fifo_output_fire})
                2'b10: write_fifo_level <= write_fifo_level + 1'b1;
                2'b01: write_fifo_level <= write_fifo_level - 1'b1;
                default: begin end
            endcase

            if (write_fifo_input_fire) begin
                write_fifo_start[write_fifo_write_pointer]
                    <= reconstruction_write_start;
                write_fifo_last[write_fifo_write_pointer]
                    <= reconstruction_write_last;
                write_fifo_frame_id[write_fifo_write_pointer]
                    <= reconstruction_frame_id;
                write_fifo_stripe_id[write_fifo_write_pointer]
                    <= reconstruction_stripe_id;
                write_fifo_plane[write_fifo_write_pointer]
                    <= reconstruction_plane;
                write_fifo_address[write_fifo_write_pointer]
                    <= reconstruction_address;
                write_fifo_data[write_fifo_write_pointer]
                    <= reconstruction_data;
                write_fifo_write_pointer <= write_fifo_write_pointer + 1'b1;
            end

            if (write_fifo_output_fire)
                write_fifo_read_pointer <= write_fifo_read_pointer + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            saturation_error <= 1'b0;
        end else begin
            if (transform_saturated)
                saturation_error <= 1'b1;
        end
    end

    generate if (ENABLE_DIAGNOSTICS) begin : residual_diagnostics
    always_ff @(posedge clk) begin
        if (!rst_n)
            residual_xor <= 16'd0;
        else if (transform_pixel_valid && transform_pixel_ready)
            residual_xor <= residual_xor ^ transform_pixel_residual;
    end
    end else begin : no_residual_diagnostics
        assign residual_xor = 16'd0;
    end endgenerate

    logic unused;
    assign unused = stripe_done ^ transform_pixel_last ^ transform_done
                  ^ (^completed_frame_id) ^ (^completed_stripe_id)
                  ^ (^completed_quality) ^ full_command_enhanced;
endmodule
