module receiver_base_decode_pipeline #(
    parameter integer CTU_COUNT = 80
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
    wire base_stripe_start = record_valid && record_ready
                           && (fragment_index == 0);
    wire full_command_pop = full_command_ready
                          && reconstruction_block_start_ready;

    receiver_base_enhancement_combiner combiner (
        .clk(clk), .rst_n(rst_n),
        .stripe_start(base_stripe_start),
        .stripe_enhancement_available(record_enhancement_available),
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
        .command_valid(full_command_valid),
        .command_ready(full_command_pop),
        .command_ctu_index(full_command_ctu_index),
        .command_block_index(full_command_block_index),
        .command_plane(full_command_plane),
        .command_mode(full_command_mode),
        .command_quality(full_command_quality),
        .command_frame_id(full_command_frame_id),
        .command_stripe_id(full_command_stripe_id),
        .command_coefficients(full_command_coefficients),
        .command_enhanced(full_command_enhanced),
        .enhanced_block_count(enhanced_block_count),
        .fallback_block_count(enhancement_fallback_block_count),
        .late_stripe_count(enhancement_late_stripe_count),
        .alignment_error(enhancement_alignment_error)
    );

    logic transform_pixel_valid, transform_pixel_ready;
    logic [5:0] transform_pixel_index;
    logic signed [15:0] transform_pixel_residual;
    logic signed [15:0] transform_pixel_reference_residual;
    logic transform_pixel_last;
    logic [6:0] transform_pixel_ctu_index;
    logic [2:0] transform_pixel_block_index;
    logic [1:0] transform_pixel_plane, transform_pixel_mode;
    logic transform_done, transform_saturated;
    wire transform_command_fire = full_command_valid && full_command_pop;

    receiver_full_idct8_32 inverse_transform (
        .clk(clk), .rst_n(rst_n),
        .command_valid(full_command_valid && reconstruction_block_start_ready),
        .command_ready(full_command_ready),
        .command_ctu_index(full_command_ctu_index),
        .command_block_index(full_command_block_index),
        .command_plane(full_command_plane), .command_mode(full_command_mode),
        .command_quality(full_command_quality),
        .command_coefficients(full_command_coefficients),
        .pixel_valid(transform_pixel_valid),
        .pixel_ready(transform_pixel_ready),
        .pixel_index(transform_pixel_index),
        .pixel_residual(transform_pixel_residual),
        .pixel_reference_residual(transform_pixel_reference_residual),
        .pixel_last(transform_pixel_last),
        .pixel_ctu_index(transform_pixel_ctu_index),
        .pixel_block_index(transform_pixel_block_index),
        .pixel_plane(transform_pixel_plane),
        .pixel_mode(transform_pixel_mode),
        .done(transform_done), .busy(transform_busy),
        .saturated(transform_saturated)
    );

    receiver_base_intra_reconstruct #(.CTU_COUNT(CTU_COUNT)) reconstruction (
        .clk(clk), .rst_n(rst_n),
        .block_start_valid(transform_command_fire),
        .block_start_ctu_index(full_command_ctu_index),
        .block_start_block_index(full_command_block_index),
        .block_start_mode(full_command_mode),
        .block_start_frame_id(full_command_frame_id),
        .block_start_stripe_id(full_command_stripe_id),
        .block_start_ready(reconstruction_block_start_ready),
        .pixel_valid(transform_pixel_valid),
        .pixel_ready(transform_pixel_ready),
        .pixel_index(transform_pixel_index),
        .pixel_residual(transform_pixel_residual),
        .pixel_reference_residual(transform_pixel_reference_residual),
        .pixel_ctu_index(transform_pixel_ctu_index),
        .pixel_block_index(transform_pixel_block_index),
        .pixel_plane(transform_pixel_plane),
        .pixel_mode(transform_pixel_mode),
        .write_valid(decoded_write_valid),
        .write_ready(decoded_write_ready),
        .write_start(decoded_write_start), .write_last(decoded_write_last),
        .write_frame_id(decoded_frame_id),
        .write_stripe_id(decoded_stripe_id), .write_plane(decoded_plane),
        .write_address(decoded_address), .write_data(decoded_data),
        .mode_error(prediction_mode_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            saturation_error <= 1'b0;
            residual_xor <= 16'd0;
        end else begin
            if (transform_saturated)
                saturation_error <= 1'b1;
            if (transform_pixel_valid && transform_pixel_ready)
                residual_xor <= residual_xor ^ transform_pixel_residual;
        end
    end

    logic unused;
    assign unused = stripe_done ^ transform_pixel_last ^ transform_done
                  ^ (^completed_frame_id) ^ (^completed_stripe_id)
                  ^ (^completed_quality) ^ full_command_enhanced;
endmodule
