`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */

module t20f169_receiver #(
    parameter SIM_ACCELERATED_VIDEO = 1'b0,
    parameter SIM_UNBOUNDED_OUTPUT = 1'b0
) (
    input  wire       CLK_48Mhz,
    output wire       pll_reset,
    input  wire       pll_lock,
    input  wire       pll_60Mhz,
    input  wire       pll_24Mhz,
    output wire       pll2_reset,
    input  wire       pll2_lock,
    input  wire       hdmi_fast_clk,
    input  wire       hdmi_half_pixel_clk,
    input  wire       hdmi_pixel_clk,
    output wire [4:0] hdmi_data0_5b,
    output wire [4:0] hdmi_data1_5b,
    output wire [4:0] hdmi_data2_5b,
    input  wire       SPI_CLK,
    input  wire       SPI_CS,
    input  wire       SPI_MOSI,
    output wire       SPI_MISO,
    input  wire       PAR_CS,
    output wire       PAR_CLK,
    input  wire [3:0] PAR_D,
    output wire [5:0] LED,
    output wire       CSI_MCLK,
    input  wire       CSI_PCLK,
    input  wire       CSI_VSYNC,
    input  wire       CSI_HSYNC,
    input  wire [7:0] CSI_D
);
    // Full JPEG-compatible 8x8 DCT profile. The 32-DSP transform consumes the
    // complete enhancement layer and is paced by the two decoded stripe banks.

    localparam ENABLE_ENHANCEMENT = 1'b1;
    localparam ENABLE_LF = 1'b0;
    // The decoded-video build owns the stripe-buffer input. Keeping the raw
    // parser path here creates a long combinational arbitration path from
    // parser fragment metadata to decoded bank-control enables.
    localparam ENABLE_RAW_DEBUG = 1'b0;

    reg [3:0] reset_60_sync;
    reg [3:0] reset_24_sync;
    reg [3:0] reset_pixel_sync;
    reg [3:0] reset_half_sync;
    wire reset_60_n = reset_60_sync[3];
    wire reset_24_n = reset_24_sync[3];
    wire reset_pixel_n = reset_pixel_sync[3];
    wire reset_half_n = reset_half_sync[3];

    // PLL-independent SPI diagnostic. While the 48 MHz PLL domain is held in
    // reset, command 0x80 returns D5 D1. Seeing that pair at the ESP proves
    // the four physical SPI nets and mode-0 timing without relying on CLK48.
    reg [2:0] emergency_spi_bit;
    reg [3:0] emergency_spi_byte;
    reg [7:0] emergency_spi_rx;
    reg [7:0] emergency_spi_command;
    reg clk48_seen = 1'b0;
    always @(posedge CLK_48Mhz)
        clk48_seen <= 1'b1;

    always @(posedge SPI_CLK or posedge SPI_CS) begin
        if (SPI_CS) begin
            emergency_spi_bit <= 3'd0;
            emergency_spi_byte <= 4'd0;
            emergency_spi_rx <= 8'd0;
            emergency_spi_command <= 8'd0;
        end else begin
            emergency_spi_rx <= {emergency_spi_rx[6:0], SPI_MOSI};
            if (emergency_spi_bit == 3'd7) begin
                if (emergency_spi_byte == 4'd0)
                    emergency_spi_command <= {
                        emergency_spi_rx[6:0], SPI_MOSI
                    };
                emergency_spi_byte <= emergency_spi_byte + 1'b1;
                emergency_spi_bit <= 3'd0;
            end else begin
                emergency_spi_bit <= emergency_spi_bit + 1'b1;
            end
        end
    end
    wire [7:0] emergency_spi_tx =
        (emergency_spi_command == 8'h80 && emergency_spi_byte == 4'd1)
            ? 8'hD5
        : (emergency_spi_command == 8'h80 && emergency_spi_byte == 4'd2)
            ? 8'hD1
        : (emergency_spi_command == 8'h80 && emergency_spi_byte == 4'd3)
            ? {5'b00000, clk48_seen, pll2_lock, pll_lock}
        : 8'h00;
    reg emergency_spi_miso;
    always @(negedge SPI_CLK or posedge SPI_CS) begin
        if (SPI_CS)
            emergency_spi_miso <= 1'b0;
        else
            emergency_spi_miso <= emergency_spi_tx[
                3'd7 - emergency_spi_bit
            ];
    end
    wire normal_spi_miso;
    assign SPI_MISO = (pll_lock && reset_60_n)
                    ? normal_spi_miso : emergency_spi_miso;

    // Efinity PLL RSTN inputs are active-low; high enables both PLLs.
    assign pll_reset = 1'b1;
    assign pll2_reset = 1'b1;
    assign CSI_MCLK = 1'b0;

    always @(posedge pll_60Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_60_sync <= 4'b0000;
        else
            reset_60_sync <= {reset_60_sync[2:0], 1'b1};
    end

    always @(posedge pll_24Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_24_sync <= 4'b0000;
        else
            reset_24_sync <= {reset_24_sync[2:0], 1'b1};
    end

    always @(posedge hdmi_pixel_clk or negedge pll2_lock) begin
        if (!pll2_lock)
            reset_pixel_sync <= 4'b0000;
        else
            reset_pixel_sync <= {reset_pixel_sync[2:0], 1'b1};
    end

    always @(posedge hdmi_half_pixel_clk or negedge pll2_lock) begin
        if (!pll2_lock)
            reset_half_sync <= 4'b0000;
        else
            reset_half_sync <= {reset_half_sync[2:0], 1'b1};
    end

    wire [11:0] video_x;
    wire [9:0] video_y;
    wire timing_de, timing_hsync, timing_vsync, frame_start;
    receiver_video_timing_720p #(
        .SIMULATION_STRIPE_BOUNDARIES(SIM_ACCELERATED_VIDEO)
    ) timing (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .x(video_x), .y(video_y), .data_enable(timing_de),
        .hsync(timing_hsync), .vsync(timing_vsync),
        .frame_start(frame_start)
    );

    reg [31:0] hdmi_frame_count;
    reg [31:0] frame_gray;
    always @(posedge hdmi_pixel_clk) begin
        if (!reset_pixel_n) begin
            hdmi_frame_count <= 32'd0;
            frame_gray <= 32'd0;
        end else if (frame_start) begin
            hdmi_frame_count <= hdmi_frame_count + 1'b1;
            frame_gray <= (hdmi_frame_count + 1'b1)
                        ^ ((hdmi_frame_count + 1'b1) >> 1);
        end
    end


    wire osd_clear_request, osd_clear_busy, osd_clear_done;
    wire osd_write_valid, osd_write_ready;
    wire [12:0] osd_write_address;
    wire [39:0] osd_write_data;
    wire osd_attribute_write_valid, osd_attribute_write_ready;
    wire [11:0] osd_attribute_write_address;
    wire [9:0] osd_attribute_write_data;
    wire osd_enable_control;
    wire [23:0] osd_rgb_control;
    wire osd_config_toggle_control;
    wire [1:0] test_pattern_mode_control;
    wire test_pattern_toggle_control;
    wire link_drain_enable;
    wire [5:0] led_override_mask, led_manual_on;
    wire spi_command_error;

    wire [9:0] link_entry;
    wire link_entry_valid;
    reg [9:0] parser_entry;
    reg parser_entry_valid;
    wire [12:0] link_write_level;
    wire [12:0] link_read_level;
    wire link_clock_enabled_24;
    wire link_warning_24;
    wire link_overflow_24;
    wire link_framing_24;
    wire link_parser_entry_ready;
    // The decoder build continuously drains ingress. The SPI drain switch was
    // useful during FIFO bring-up, but routing it across the device into every
    // parser header-register enable creates a long non-functional path.
    wire parser_entry_advance = !parser_entry_valid
                              || link_parser_entry_ready;
    receiver_parallel_ingress parallel_ingress (
        .link_clk(pll_24Mhz), .link_rst_n(reset_24_n),
        .par_clk(PAR_CLK), .par_cs(PAR_CS), .par_data(PAR_D),
        .read_clk(pll_60Mhz), .read_rst_n(reset_60_n),
        .output_entry(link_entry), .output_valid(link_entry_valid),
        .output_ready(parser_entry_advance),
        .write_level(link_write_level), .read_level(link_read_level),
        .par_clock_enabled(link_clock_enabled_24),
        .warning_level(link_warning_24),
        .overflow_error(link_overflow_24),
        .framing_error(link_framing_24)
    );

    // The inferred synchronous FIFO RAM exposes its registered RDATA directly.
    // This elastic register isolates that RAM output from parser control while
    // retaining one-entry-per-cycle throughput after the first entry.
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            parser_entry <= 10'd0;
            parser_entry_valid <= 1'b0;
        end else if (parser_entry_advance) begin
            if (link_entry_valid) begin
                parser_entry <= link_entry;
                parser_entry_valid <= 1'b1;
            end else begin
                parser_entry_valid <= 1'b0;
            end
        end
    end

    wire parser_record_valid;
    wire [7:0] parser_record_type;
    wire [15:0] parser_record_sequence;
    wire [15:0] parser_display_frame_id, parser_source_frame_id;
    wire [7:0] parser_stripe_id, parser_quality;
    wire [7:0] parser_fragment_index, parser_fragment_count;
    wire [7:0] parser_record_flags;
    wire [15:0] parser_payload_length;
    wire [7:0] parser_payload_data;
    wire parser_payload_valid, parser_payload_last, parser_busy;
    wire parser_record_ready, parser_payload_ready;
    wire stripe_record_ready, stripe_payload_ready;
    wire base_record_ready, base_payload_ready;
    wire lf_record_ready, lf_payload_ready;
    wire enhancement_record_ready, enhancement_payload_ready;
    reg [2:0] payload_route;
    receiver_link_record_parser #(
        .ENABLE_COUNTERS(1'b0)
    ) link_parser (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .entry(parser_entry),
        .entry_valid(parser_entry_valid),
        .entry_ready(link_parser_entry_ready),
        .record_valid(parser_record_valid),
        .record_ready(parser_record_ready),
        .record_type(parser_record_type),
        .record_sequence(parser_record_sequence),
        .display_frame_id(parser_display_frame_id),
        .source_frame_id(parser_source_frame_id),
        .stripe_id(parser_stripe_id), .quality(parser_quality),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .record_flags(parser_record_flags),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(parser_payload_valid),
        .payload_ready(parser_payload_ready),
        .payload_last(parser_payload_last), .parser_busy(parser_busy),
        // These bring-up counters are not exposed by the production SPI
        // status page. Open outputs let synthesis remove their incrementers.
        .accepted_count(),
        .rejected_count(),
        .crc_error_count(),
        .length_error_count(),
        .framing_error_count()
    );

    wire [23:0] stripe_rgb;
    wire stripe_de, stripe_hsync, stripe_vsync;
    wire [31:0] stripe_displayed_count, stripe_missing_count;
    wire decoded_write_valid, decoded_write_ready;
    wire decoded_write_start, decoded_write_last;
    wire [15:0] decoded_frame_id;
    wire [7:0] decoded_stripe_id;
    wire [1:0] decoded_plane;
    wire [14:0] decoded_address;
    wire [7:0] decoded_data;
    receiver_yuv420_stripe_buffers stripe_buffers (
        .write_clk(pll_60Mhz), .write_rst_n(reset_60_n),
        .record_valid(ENABLE_RAW_DEBUG && parser_record_valid
                      && (parser_record_type == 8'h20)),
        .record_ready(stripe_record_ready),
        .record_type(parser_record_type),
        .display_frame_id(parser_display_frame_id),
        .stripe_id(parser_stripe_id),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(ENABLE_RAW_DEBUG && parser_payload_valid
                       && (payload_route == 3'd1)),
        .payload_ready(stripe_payload_ready),
        .payload_last(parser_payload_last),
        .decoded_write_valid(decoded_write_valid),
        .decoded_write_ready(decoded_write_ready),
        .decoded_write_start(decoded_write_start),
        .decoded_write_last(decoded_write_last),
        .decoded_frame_id(decoded_frame_id),
        .decoded_stripe_id(decoded_stripe_id),
        .decoded_plane(decoded_plane), .decoded_address(decoded_address),
        .decoded_data(decoded_data),
        .pixel_clk(hdmi_pixel_clk), .pixel_rst_n(reset_pixel_n),
        .x(video_x), .y(video_y), .data_enable(timing_de),
        .hsync(timing_hsync), .vsync(timing_vsync),
        .rgb(stripe_rgb), .data_enable_out(stripe_de),
        .hsync_out(stripe_hsync), .vsync_out(stripe_vsync),
        .completed_stripe_count(),
        .rejected_stripe_count(),
        .displayed_stripe_count(stripe_displayed_count),
        .missing_stripe_count(stripe_missing_count)
    );

    // Record metadata and payload replay are separate phases. Latch the
    // selected consumer at the metadata handshake so payload bytes cannot be
    // misrouted when the parser advances to its next internal state.
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            payload_route <= 3'd0;
        end else begin
            if (parser_record_valid && parser_record_ready) begin
                if (parser_payload_length == 0)
                    payload_route <= 3'd0;
                else if (parser_record_type == 8'h20)
                    payload_route <= 3'd1;
                else if (parser_record_type == 8'h10)
                    payload_route <= 3'd2;
                else if (parser_record_type == 8'h12)
                    payload_route <= 3'd3;
                else if (parser_record_type == 8'h11)
                    payload_route <= 3'd4;
                else
                    payload_route <= 3'd5;
            end
            if (parser_payload_valid && parser_payload_ready
                && parser_payload_last)
                payload_route <= 3'd0;
        end
    end

    assign parser_record_ready = (parser_record_type == 8'h20)
                               ? (ENABLE_RAW_DEBUG ? stripe_record_ready : 1'b1)
                               : (parser_record_type == 8'h10)
                               ? base_record_admission_ready
                               : (parser_record_type == 8'h12)
                               ? lf_record_ready
                               : (parser_record_type == 8'h11)
                               ? enhancement_record_ready : 1'b1;
    assign parser_payload_ready = (payload_route == 3'd1)
                                ? (ENABLE_RAW_DEBUG ? stripe_payload_ready : 1'b1)
                                : (payload_route == 3'd2)
                                ? base_payload_ready
                                : (payload_route == 3'd3)
                                ? lf_payload_ready
                                : (payload_route == 3'd4)
                                ? enhancement_payload_ready : 1'b1;

    wire base_record_admission_ready;
    reg base_record_admission_granted;
    wire [31:0] base_completed_count;
    wire [1:0] transform_fifo_level;
    wire transform_busy, transform_saturation_error;
    wire prediction_mode_error;
    wire [15:0] base_residual_xor;
    wire base_write_valid, base_write_ready;
    wire base_write_start, base_write_last;
    wire [15:0] base_write_frame_id;
    wire [7:0] base_write_stripe_id;
    wire [1:0] base_write_plane;
    wire [14:0] base_write_address;
    wire [7:0] base_write_data;
    wire enhancement_event_valid, enhancement_event_ready;
    wire [1:0] enhancement_event_kind, enhancement_event_plane;
    wire [6:0] enhancement_event_ctu_index;
    wire [2:0] enhancement_event_block_index;
    wire [5:0] enhancement_event_scan_index;
    wire signed [11:0] enhancement_event_coefficient;
    wire [7:0] enhancement_event_quality, enhancement_event_stripe_id;
    wire [15:0] enhancement_event_frame_id;
    wire enhancement_decoder_event_valid;
    wire enhancement_decoder_event_ready;
    wire [1:0] enhancement_decoder_event_kind;
    wire [6:0] enhancement_decoder_event_ctu_index;
    wire [2:0] enhancement_decoder_event_block_index;
    wire [1:0] enhancement_decoder_event_plane;
    wire [5:0] enhancement_decoder_event_scan_index;
    wire signed [11:0] enhancement_decoder_event_coefficient;
    wire [7:0] enhancement_decoder_event_quality;
    wire [15:0] enhancement_decoder_event_frame_id;
    wire [7:0] enhancement_decoder_event_stripe_id;
    wire enhancement_stored_valid;
    wire [15:0] enhancement_stored_frame_id;
    wire [7:0] enhancement_stored_stripe_id;
    wire matching_enhancement_available = enhancement_stored_valid
        && (enhancement_stored_frame_id == parser_display_frame_id)
        && (enhancement_stored_stripe_id == parser_stripe_id);
    receiver_base_decode_pipeline #(
        .ENABLE_ENHANCEMENT(ENABLE_ENHANCEMENT),
        .ENABLE_DIAGNOSTICS(1'b0)
    ) base_decoder (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        // Admission is registered only for record type 0x10, so repeating
        // the compare here only routes parser metadata into the entropy CE.
        .record_valid(parser_record_valid && base_record_admission_ready),
        .record_ready(base_record_ready),
        .display_frame_id(parser_display_frame_id),
        .stripe_id(parser_stripe_id), .quality(parser_quality),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .record_flags(parser_record_flags),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(parser_payload_valid && (payload_route == 3'd2)),
        .payload_ready(base_payload_ready),
        .payload_last(parser_payload_last),
        .record_enhancement_available(matching_enhancement_available),
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
        .decoded_write_valid(base_write_valid),
        .decoded_write_ready(base_write_ready),
        .decoded_write_start(base_write_start),
        .decoded_write_last(base_write_last),
        .decoded_frame_id(base_write_frame_id),
        .decoded_stripe_id(base_write_stripe_id),
        .decoded_plane(base_write_plane),
        .decoded_address(base_write_address),
        .decoded_data(base_write_data),
        .block_fifo_level(transform_fifo_level),
        .transform_busy(transform_busy),
        .saturation_error(transform_saturation_error),
        .prediction_mode_error(prediction_mode_error),
        .residual_xor(base_residual_xor),
        .completed_stripe_count(base_completed_count),
        .rejected_stripe_count(),
        .syntax_error_count(),
        .enhanced_block_count(),
        .enhancement_fallback_block_count(),
        .enhancement_late_stripe_count(),
        .enhancement_alignment_error()
    );

    wire lf_busy;
    wire [31:0] lf_completed_count, lf_rejected_count;
    wire lf_write_valid, lf_write_ready;
    wire lf_write_start, lf_write_last;
    wire [15:0] lf_write_frame_id;
    wire [7:0] lf_write_stripe_id;
    wire [1:0] lf_write_plane;
    wire [14:0] lf_write_address;
    wire [7:0] lf_write_data;
    generate if (ENABLE_LF) begin : lf_path
        receiver_lf_stripe_decoder lf_decoder (
            .clk(pll_60Mhz), .rst_n(reset_60_n),
            .record_valid(parser_record_valid && (parser_record_type == 8'h12)),
            .record_ready(lf_record_ready),
            .display_frame_id(parser_display_frame_id),
            .stripe_id(parser_stripe_id),
            .fragment_index(parser_fragment_index),
            .fragment_count(parser_fragment_count),
            .record_flags(parser_record_flags),
            .payload_length(parser_payload_length),
            .payload_data(parser_payload_data),
            .payload_valid(parser_payload_valid && (payload_route == 3'd3)),
            .payload_ready(lf_payload_ready),
            .payload_last(parser_payload_last),
            .decoded_write_valid(lf_write_valid),
            .decoded_write_ready(lf_write_ready),
            .decoded_write_start(lf_write_start),
            .decoded_write_last(lf_write_last),
            .decoded_frame_id(lf_write_frame_id),
            .decoded_stripe_id(lf_write_stripe_id),
            .decoded_plane(lf_write_plane),
            .decoded_address(lf_write_address),
            .decoded_data(lf_write_data), .busy(lf_busy),
            .completed_stripe_count(lf_completed_count),
            .rejected_stripe_count(lf_rejected_count)
        );
    end else begin : no_lf_path
        assign lf_record_ready = 1'b1;
        assign lf_payload_ready = 1'b1;
        assign lf_busy = 1'b0;
        assign lf_completed_count = 32'd0;
        assign lf_rejected_count = 32'd0;
        assign lf_write_valid = 1'b0;
        assign lf_write_start = 1'b0;
        assign lf_write_last = 1'b0;
        assign lf_write_frame_id = 16'd0;
        assign lf_write_stripe_id = 8'd0;
        assign lf_write_plane = 2'd0;
        assign lf_write_address = 15'd0;
        assign lf_write_data = 8'd0;
    end endgenerate

    wire enhancement_replay_record_valid, enhancement_replay_record_ready;
    wire enhancement_replay_request_ready;
    reg enhancement_replay_request;
    reg [15:0] enhancement_replay_request_frame_id;
    reg [7:0] enhancement_replay_request_stripe_id;
    wire enhancement_replay_payload_valid, enhancement_replay_payload_ready;
    wire enhancement_replay_payload_last;
    wire [7:0] enhancement_replay_payload_data;
    wire [15:0] enhancement_replay_frame_id;
    wire [7:0] enhancement_replay_stripe_id;
    wire [7:0] enhancement_replay_quality;
    wire [7:0] enhancement_replay_record_flags;
    wire [15:0] enhancement_replay_payload_length;
    wire enhancement_decoder_record_ready;
    reg enhancement_header_valid;
    reg [15:0] enhancement_header_frame_id;
    reg [7:0] enhancement_header_stripe_id;
    reg [7:0] enhancement_header_quality;
    reg [7:0] enhancement_header_record_flags;
    reg [15:0] enhancement_header_payload_length;
    wire [31:0] enhancement_stored_count;
    wire [31:0] enhancement_store_rejected_count;
    wire [31:0] enhancement_replayed_count;
    wire [31:0] enhancement_request_miss_count;
    reg [15:0] enhancement_coefficient_xor;
    // Register the stripe-level admission decision before it reaches the
    // base decoder. Besides keeping base behind the matching enhancement
    // replay, this breaks the frame/stripe compare out of the entropy
    // decoder's high-fanout record-valid/clock-enable path.
    assign base_record_admission_ready = base_record_ready
        && base_record_admission_granted;
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            base_record_admission_granted <= 1'b0;
            enhancement_replay_request <= 1'b0;
            enhancement_replay_request_frame_id <= 16'd0;
            enhancement_replay_request_stripe_id <= 8'd0;
        end else begin
            enhancement_replay_request <= 1'b0;
            if (base_record_admission_granted) begin
                if (parser_record_valid && parser_record_ready
                    && (parser_record_type == 8'h10))
                    base_record_admission_granted <= 1'b0;
            end else if (parser_record_valid
                         && (parser_record_type == 8'h10)
                         && (!ENABLE_ENHANCEMENT
                             || (parser_fragment_index != 0)
                             || !matching_enhancement_available
                             || (enhancement_replay_request_ready
                                 && enhancement_replay_record_ready))) begin
                base_record_admission_granted <= 1'b1;
            end
            if (parser_record_valid && parser_record_ready
                && (parser_record_type == 8'h10)
                && (parser_fragment_index == 0)
                && matching_enhancement_available) begin
                enhancement_replay_request <= 1'b1;
                enhancement_replay_request_frame_id <=
                    parser_display_frame_id;
                enhancement_replay_request_stripe_id <= parser_stripe_id;
            end
        end
    end

    generate if (ENABLE_ENHANCEMENT) begin : enhancement_path
    receiver_enhancement_store_replay enhancement_store (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .record_valid(parser_record_valid && (parser_record_type == 8'h11)),
        .record_ready(enhancement_record_ready),
        .display_frame_id(parser_display_frame_id),
        .stripe_id(parser_stripe_id), .quality(parser_quality),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .record_flags(parser_record_flags),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(parser_payload_valid && (payload_route == 3'd4)),
        .payload_ready(enhancement_payload_ready),
        .payload_last(parser_payload_last),
        .request_valid(enhancement_replay_request),
        .request_frame_id(enhancement_replay_request_frame_id),
        .request_stripe_id(enhancement_replay_request_stripe_id),
        .request_ready(enhancement_replay_request_ready),
        .replay_record_valid(enhancement_replay_record_valid),
        .replay_record_ready(enhancement_replay_record_ready),
        .replay_frame_id(enhancement_replay_frame_id),
        .replay_stripe_id(enhancement_replay_stripe_id),
        .replay_quality(enhancement_replay_quality),
        .replay_record_flags(enhancement_replay_record_flags),
        .replay_payload_length(enhancement_replay_payload_length),
        .replay_payload_data(enhancement_replay_payload_data),
        .replay_payload_valid(enhancement_replay_payload_valid),
        .replay_payload_ready(enhancement_replay_payload_ready),
        .replay_payload_last(enhancement_replay_payload_last),
        .stored_valid(enhancement_stored_valid),
        .stored_frame_id(enhancement_stored_frame_id),
        .stored_stripe_id(enhancement_stored_stripe_id),
        .stored_count(enhancement_stored_count),
        .rejected_count(enhancement_store_rejected_count),
        .replayed_count(enhancement_replayed_count),
        .request_miss_count(enhancement_request_miss_count)
    );

    // One-entry header register slice keeps replay metadata validation out of
    // the enhancement event FSM clock-enable cone. Payload backpressure holds
    // the replay until the decoder has accepted this registered header.
    assign enhancement_replay_record_ready = !enhancement_header_valid;
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            enhancement_header_valid <= 1'b0;
            enhancement_header_frame_id <= 16'd0;
            enhancement_header_stripe_id <= 8'd0;
            enhancement_header_quality <= 8'd0;
            enhancement_header_record_flags <= 8'd0;
            enhancement_header_payload_length <= 16'd0;
        end else begin
            if (!enhancement_header_valid
                && enhancement_replay_record_valid) begin
                enhancement_header_valid <= 1'b1;
                enhancement_header_frame_id <= enhancement_replay_frame_id;
                enhancement_header_stripe_id <= enhancement_replay_stripe_id;
                enhancement_header_quality <= enhancement_replay_quality;
                enhancement_header_record_flags
                    <= enhancement_replay_record_flags;
                enhancement_header_payload_length
                    <= enhancement_replay_payload_length;
            end else if (enhancement_header_valid
                         && enhancement_decoder_record_ready) begin
                enhancement_header_valid <= 1'b0;
            end
        end
    end

    receiver_enhancement_entropy_decoder #(
        .ENABLE_COUNTERS(1'b0)
    ) enhancement_decoder (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .record_valid(enhancement_header_valid),
        .record_ready(enhancement_decoder_record_ready),
        .display_frame_id(enhancement_header_frame_id),
        .stripe_id(enhancement_header_stripe_id),
        .quality(enhancement_header_quality),
        .fragment_index(8'd0), .fragment_count(8'd1),
        .record_flags(enhancement_header_record_flags),
        .payload_length(enhancement_header_payload_length),
        .payload_data(enhancement_replay_payload_data),
        .payload_valid(enhancement_replay_payload_valid),
        .payload_ready(enhancement_replay_payload_ready),
        .payload_last(enhancement_replay_payload_last),
        .event_valid(enhancement_decoder_event_valid),
        .event_ready(enhancement_decoder_event_ready),
        .event_kind(enhancement_decoder_event_kind),
        .event_ctu_index(enhancement_decoder_event_ctu_index),
        .event_block_index(enhancement_decoder_event_block_index),
        .event_plane(enhancement_decoder_event_plane),
        .event_scan_index(enhancement_decoder_event_scan_index),
        .event_coefficient(enhancement_decoder_event_coefficient),
        .event_quality(enhancement_decoder_event_quality),
        .event_frame_id(enhancement_decoder_event_frame_id),
        .event_stripe_id(enhancement_decoder_event_stripe_id),
        .completed_stripe_count(),
        .rejected_stripe_count(),
        .syntax_error_count()
    );

    // Registered event slice breaks the combiner state/ready cone before it
    // reaches the entropy decoder output clock enables. Entropy decoding
    // naturally takes multiple cycles per event, so the deliberate empty
    // cycle after each accepted event does not reduce its useful throughput.
    (* syn_keep = 1, syn_maxfan = 4 *)
    reg enhancement_event_buffer_valid;
    reg [1:0] enhancement_event_buffer_kind;
    reg [6:0] enhancement_event_buffer_ctu_index;
    reg [2:0] enhancement_event_buffer_block_index;
    reg [1:0] enhancement_event_buffer_plane;
    reg [5:0] enhancement_event_buffer_scan_index;
    reg signed [11:0] enhancement_event_buffer_coefficient;
    reg [7:0] enhancement_event_buffer_quality;
    reg [15:0] enhancement_event_buffer_frame_id;
    reg [7:0] enhancement_event_buffer_stripe_id;

    assign enhancement_decoder_event_ready = !enhancement_event_buffer_valid;
    assign enhancement_event_valid = enhancement_event_buffer_valid;
    assign enhancement_event_kind = enhancement_event_buffer_kind;
    assign enhancement_event_ctu_index = enhancement_event_buffer_ctu_index;
    assign enhancement_event_block_index = enhancement_event_buffer_block_index;
    assign enhancement_event_plane = enhancement_event_buffer_plane;
    assign enhancement_event_scan_index = enhancement_event_buffer_scan_index;
    assign enhancement_event_coefficient = enhancement_event_buffer_coefficient;
    assign enhancement_event_quality = enhancement_event_buffer_quality;
    assign enhancement_event_frame_id = enhancement_event_buffer_frame_id;
    assign enhancement_event_stripe_id = enhancement_event_buffer_stripe_id;

    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            enhancement_event_buffer_valid <= 1'b0;
        end else begin
            if (enhancement_event_buffer_valid && enhancement_event_ready)
                enhancement_event_buffer_valid <= 1'b0;
            if (enhancement_decoder_event_valid
                && enhancement_decoder_event_ready) begin
                enhancement_event_buffer_valid <= 1'b1;
                enhancement_event_buffer_kind <= enhancement_decoder_event_kind;
                enhancement_event_buffer_ctu_index
                    <= enhancement_decoder_event_ctu_index;
                enhancement_event_buffer_block_index
                    <= enhancement_decoder_event_block_index;
                enhancement_event_buffer_plane <= enhancement_decoder_event_plane;
                enhancement_event_buffer_scan_index
                    <= enhancement_decoder_event_scan_index;
                enhancement_event_buffer_coefficient
                    <= enhancement_decoder_event_coefficient;
                enhancement_event_buffer_quality
                    <= enhancement_decoder_event_quality;
                enhancement_event_buffer_frame_id
                    <= enhancement_decoder_event_frame_id;
                enhancement_event_buffer_stripe_id
                    <= enhancement_decoder_event_stripe_id;
            end
        end
    end
    end else begin : no_enhancement_path
        // Existing files and ESP32 firmware remain compatible: type 0x11
        // records are consumed at full speed and deliberately discarded.
        assign enhancement_record_ready = 1'b1;
        assign enhancement_payload_ready = 1'b1;
        assign enhancement_event_valid = 1'b0;
        assign enhancement_event_kind = 2'd0;
        assign enhancement_event_ctu_index = 7'd0;
        assign enhancement_event_block_index = 3'd0;
        assign enhancement_event_plane = 2'd0;
        assign enhancement_event_scan_index = 6'd0;
        assign enhancement_event_coefficient = 12'sd0;
        assign enhancement_event_quality = 8'd0;
        assign enhancement_event_frame_id = 16'd0;
        assign enhancement_event_stripe_id = 8'd0;
        assign enhancement_stored_valid = 1'b0;
        assign enhancement_stored_frame_id = 16'd0;
        assign enhancement_stored_stripe_id = 8'd0;
        assign enhancement_replay_record_valid = 1'b0;
        assign enhancement_replay_record_ready = 1'b0;
        assign enhancement_replay_request_ready = 1'b1;
        assign enhancement_replay_payload_valid = 1'b0;
        assign enhancement_replay_payload_ready = 1'b0;
        assign enhancement_replay_payload_last = 1'b0;
        assign enhancement_replay_payload_data = 8'd0;
        assign enhancement_replay_frame_id = 16'd0;
        assign enhancement_replay_stripe_id = 8'd0;
        assign enhancement_replay_quality = 8'd0;
        assign enhancement_replay_record_flags = 8'd0;
        assign enhancement_replay_payload_length = 16'd0;
        assign enhancement_stored_count = 32'd0;
        assign enhancement_store_rejected_count = 32'd0;
        assign enhancement_replayed_count = 32'd0;
        assign enhancement_request_miss_count = 32'd0;
    end endgenerate

    always @(posedge pll_60Mhz) begin
        if (!reset_60_n)
            enhancement_coefficient_xor <= 16'd0;
        else if (enhancement_event_valid && enhancement_event_ready
                 && (enhancement_event_kind == 2'd1))
            enhancement_coefficient_xor <= enhancement_coefficient_xor
                ^ {{4{enhancement_event_coefficient[11]}},
                   enhancement_event_coefficient};
    end

    wire [1:0] decoded_write_owner;
    generate if (ENABLE_LF) begin : decoded_write_merge
    receiver_decoded_write_arbiter2 decoded_write_arbiter (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .base_valid(base_write_valid), .base_ready(base_write_ready),
        .base_start(base_write_start), .base_last(base_write_last),
        .base_frame_id(base_write_frame_id),
        .base_stripe_id(base_write_stripe_id),
        .base_plane(base_write_plane), .base_address(base_write_address),
        .base_data(base_write_data),
        .lf_valid(lf_write_valid), .lf_ready(lf_write_ready),
        .lf_start(lf_write_start), .lf_last(lf_write_last),
        .lf_frame_id(lf_write_frame_id),
        .lf_stripe_id(lf_write_stripe_id), .lf_plane(lf_write_plane),
        .lf_address(lf_write_address), .lf_data(lf_write_data),
        .write_valid(decoded_write_valid), .write_ready(decoded_write_ready),
        .write_start(decoded_write_start), .write_last(decoded_write_last),
        .write_frame_id(decoded_frame_id),
        .write_stripe_id(decoded_stripe_id), .write_plane(decoded_plane),
        .write_address(decoded_address), .write_data(decoded_data),
        .owner(decoded_write_owner)
    );
    end else begin : decoded_write_base_only
        assign decoded_write_valid = base_write_valid;
        assign base_write_ready = SIM_UNBOUNDED_OUTPUT
                                ? 1'b1 : decoded_write_ready;
        assign decoded_write_start = base_write_start;
        assign decoded_write_last = base_write_last;
        assign decoded_frame_id = base_write_frame_id;
        assign decoded_stripe_id = base_write_stripe_id;
        assign decoded_plane = base_write_plane;
        assign decoded_address = base_write_address;
        assign decoded_data = base_write_data;
        assign lf_write_ready = 1'b1;
        assign decoded_write_owner = base_write_valid ? 2'd1 : 2'd0;
    end endgenerate

    reg [1:0] link_clock_sync, link_warning_sync;
    reg [1:0] link_overflow_sync, link_framing_sync;
    reg [31:0] link_byte_count, link_transaction_count;
    reg [7:0] link_payload_xor;
    reg [7:0] parser_payload_xor;
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            link_clock_sync <= 2'd0;
            link_warning_sync <= 2'd0;
            link_overflow_sync <= 2'd0;
            link_framing_sync <= 2'd0;
            link_byte_count <= 32'd0;
            link_transaction_count <= 32'd0;
            link_payload_xor <= 8'd0;
            parser_payload_xor <= 8'd0;
        end else begin
            link_clock_sync <= {link_clock_sync[0], link_clock_enabled_24};
            link_warning_sync <= {link_warning_sync[0], link_warning_24};
            link_overflow_sync <= {link_overflow_sync[0], link_overflow_24};
            link_framing_sync <= {link_framing_sync[0], link_framing_24};
            if (parser_entry_valid && link_parser_entry_ready) begin
                if (parser_entry[9:8] == 2'b10)
                    link_transaction_count <= link_transaction_count + 1'b1;
                else begin
                    link_byte_count <= link_byte_count + 1'b1;
                    link_payload_xor <= link_payload_xor ^ parser_entry[7:0];
                end
            end
            if (parser_payload_valid && parser_payload_ready)
                parser_payload_xor <= parser_payload_xor
                                      ^ parser_payload_data;
        end
    end

    reg [31:0] frame_gray_sync1, frame_gray_sync2;
    reg [31:0] frame_count_60;
    function automatic [31:0] gray_to_binary(input [31:0] value);
        integer gray_bit;
        begin
            gray_to_binary[31] = value[31];
            for (gray_bit = 30; gray_bit >= 0; gray_bit = gray_bit - 1)
                gray_to_binary[gray_bit] = gray_to_binary[gray_bit + 1]
                                         ^ value[gray_bit];
        end
    endfunction

    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            frame_gray_sync1 <= 32'd0;
            frame_gray_sync2 <= 32'd0;
            frame_count_60 <= 32'd0;
        end else begin
            frame_gray_sync1 <= frame_gray;
            frame_gray_sync2 <= frame_gray_sync1;
            frame_count_60 <= gray_to_binary(frame_gray_sync2);
        end
    end

    wire [5:0] led_auto_on = {
        reset_pixel_n, (spi_command_error | link_overflow_sync[1]
                        | link_framing_sync[1]
                        | transform_saturation_error
                        | prediction_mode_error),
        osd_clear_busy,
        pll2_lock, pll_lock, hdmi_frame_count[5]
    };

    localparam integer OSD_WORD_COUNT = 5760;
    localparam integer OSD_ATTRIBUTE_COUNT = 2400;

    receiver_spi_osd_control #(
        .OSD_WORD_COUNT(OSD_WORD_COUNT),
        .OSD_ATTRIBUTE_COUNT(OSD_ATTRIBUTE_COUNT)
    ) osd_control (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .spi_cs_n(SPI_CS), .spi_sck(SPI_CLK),
        .spi_mosi(SPI_MOSI), .spi_miso(normal_spi_miso),
        .pll2_lock(pll2_lock),
        .osd_clear_busy(osd_clear_busy),
        .osd_clear_done(osd_clear_done),
        .osd_clear_request(osd_clear_request),
        .osd_write_valid(osd_write_valid),
        .osd_write_ready(osd_write_ready),
        .osd_write_address(osd_write_address),
        .osd_write_data(osd_write_data),
        .osd_attribute_write_valid(osd_attribute_write_valid),
        .osd_attribute_write_ready(osd_attribute_write_ready),
        .osd_attribute_write_address(osd_attribute_write_address),
        .osd_attribute_write_data(osd_attribute_write_data),
        .osd_enable(osd_enable_control), .osd_rgb(osd_rgb_control),
        .osd_config_toggle(osd_config_toggle_control),
        .test_pattern_mode(test_pattern_mode_control),
        .test_pattern_toggle(test_pattern_toggle_control),
        .link_drain_enable(link_drain_enable),
        .hdmi_frame_count(frame_count_60),
        .link_fifo_level(link_read_level),
        .link_clock_enabled(link_clock_sync[1]),
        .link_warning_level(link_warning_sync[1]),
        .link_overflow_error(link_overflow_sync[1]),
        .link_framing_error(link_framing_sync[1]),
        .link_byte_count(link_byte_count),
        .link_transaction_count(link_transaction_count),
        .link_payload_xor(link_payload_xor),
        .parser_busy(parser_busy),
        .parser_record_valid(parser_record_valid),
        .parser_payload_valid(parser_payload_valid),
        .parser_record_type(parser_record_type),
        .parser_stripe_id(parser_stripe_id),
        .parser_payload_length(parser_payload_length),
        .parser_payload_xor(parser_payload_xor),
        .parser_record_sequence(parser_record_sequence),
        .parser_accepted_count(32'd0),
        .parser_rejected_count(32'd0),
        .parser_crc_error_count(32'd0),
        .parser_length_error_count(32'd0),
        .parser_framing_error_count(32'd0),
        .decoder_block_fifo_level(transform_fifo_level),
        .decoder_transform_busy(transform_busy),
        .decoder_saturation_error(transform_saturation_error),
        .decoder_residual_xor(base_residual_xor),
        .decoder_completed_count(base_completed_count),
        .decoder_rejected_count(32'd0),
        .decoder_syntax_error_count(32'd0),
        .displayed_stripe_count(stripe_displayed_count),
        .missing_stripe_count(stripe_missing_count),
        .enhancement_event_valid(enhancement_event_valid),
        .enhancement_event_kind(enhancement_event_kind),
        .enhancement_coefficient_xor(enhancement_coefficient_xor),
        // Temporary hardware bring-up view: stored, replayed and missed.
        .enhancement_completed_count(enhancement_stored_count),
        .enhancement_rejected_count(enhancement_replayed_count),
        .enhancement_syntax_error_count(enhancement_request_miss_count),
        .led_auto_on(led_auto_on),
        .led_override_mask(led_override_mask),
        .led_manual_on(led_manual_on),
        .command_error(spi_command_error)
    );

    wire osd_mask;
    wire [9:0] osd_attribute;
    wire display_de, display_hsync, display_vsync;
    receiver_osd_framebuffer #(
        .WORD_COUNT(OSD_WORD_COUNT),
        .ATTRIBUTE_COUNT(OSD_ATTRIBUTE_COUNT)
    ) osd (
        .write_clk(pll_60Mhz), .write_rst_n(reset_60_n),
        .clear_request(osd_clear_request),
        .clear_busy(osd_clear_busy), .clear_done(osd_clear_done),
        .write_valid(osd_write_valid), .write_ready(osd_write_ready),
        .write_address(osd_write_address), .write_data(osd_write_data),
        .attribute_write_valid(osd_attribute_write_valid),
        .attribute_write_ready(osd_attribute_write_ready),
        .attribute_write_address(osd_attribute_write_address),
        .attribute_write_data(osd_attribute_write_data),
        .pixel_clk(hdmi_pixel_clk), .pixel_rst_n(reset_pixel_n),
        .x(video_x), .y(video_y), .data_enable(timing_de),
        .hsync(timing_hsync), .vsync(timing_vsync),
        .osd_mask(osd_mask), .osd_attribute(osd_attribute),
        .data_enable_out(display_de),
        .hsync_out(display_hsync), .vsync_out(display_vsync)
    );

    reg [2:0] osd_toggle_sync;
    reg [2:0] test_pattern_toggle_sync;
    reg osd_enable_pixel;
    reg [23:0] osd_rgb_pixel;
    reg [1:0] test_pattern_mode_pixel;
    reg [1:0] clear_busy_pixel_sync;
    always @(posedge hdmi_pixel_clk) begin
        if (!reset_pixel_n) begin
            osd_toggle_sync <= 3'b000;
            test_pattern_toggle_sync <= 3'b000;
            osd_enable_pixel <= 1'b1;
            osd_rgb_pixel <= 24'hFFFFFF;
            test_pattern_mode_pixel <= 2'd1;
            clear_busy_pixel_sync <= 2'b11;
        end else begin
            osd_toggle_sync <= {
                osd_toggle_sync[1:0], osd_config_toggle_control
            };
            test_pattern_toggle_sync <= {
                test_pattern_toggle_sync[1:0],
                test_pattern_toggle_control
            };
            clear_busy_pixel_sync <= {
                clear_busy_pixel_sync[0], osd_clear_busy
            };
            if (osd_toggle_sync[2] != osd_toggle_sync[1]) begin
                osd_enable_pixel <= osd_enable_control;
                osd_rgb_pixel <= osd_rgb_control;
            end
            if (test_pattern_toggle_sync[2]
                != test_pattern_toggle_sync[1])
                test_pattern_mode_pixel <= test_pattern_mode_control;
        end
    end

    wire [23:0] test_pattern_rgb;
    receiver_test_pattern test_pattern (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .mode(test_pattern_mode_pixel), .x(video_x), .y(video_y),
        .rgb(test_pattern_rgb)
    );

    // Mode zero is the decoded-video path. Missing or late stripes are
    // already neutral gray; modes 1..3 remain board diagnostics.
    wire [23:0] base_rgb = (test_pattern_mode_pixel == 2'd0)
                         ? stripe_rgb : test_pattern_rgb;

    function automatic [23:0] osd_palette(
        input [3:0] color_index,
        input [23:0] programmable_color
    );
        begin
            case (color_index)
                4'h0: osd_palette = 24'h000000;
                4'h1: osd_palette = 24'h0000AA;
                4'h2: osd_palette = 24'h00AA00;
                4'h3: osd_palette = 24'h00AAAA;
                4'h4: osd_palette = 24'hAA0000;
                4'h5: osd_palette = 24'hAA00AA;
                4'h6: osd_palette = 24'hAA5500;
                4'h7: osd_palette = 24'hAAAAAA;
                4'h8: osd_palette = 24'h555555;
                4'h9: osd_palette = 24'h5555FF;
                4'hA: osd_palette = 24'h55FF55;
                4'hB: osd_palette = 24'h55FFFF;
                4'hC: osd_palette = 24'hFF5555;
                4'hD: osd_palette = 24'hFF55FF;
                4'hE: osd_palette = 24'hFFFF55;
                default: osd_palette = programmable_color;
            endcase
        end
    endfunction

    wire overlay_active = osd_enable_pixel && !clear_busy_pixel_sync[1];
    wire [23:0] osd_foreground_rgb = osd_palette(
        osd_attribute[3:0], osd_rgb_pixel
    );
    wire [23:0] osd_background_rgb = osd_palette(
        osd_attribute[7:4], osd_rgb_pixel
    );
    wire [23:0] display_rgb = !overlay_active ? base_rgb
                            : osd_mask ? osd_foreground_rgb
                            : osd_attribute[8] ? osd_background_rgb
                            : base_rgb;

    // Keep compositing and TMDS disparity calculation in separate pipeline
    // stages. This costs one pixel clock and shortens the encoder path.
    reg [23:0] encoder_rgb;
    reg encoder_de, encoder_hsync, encoder_vsync;
    always @(posedge hdmi_pixel_clk) begin
        if (!reset_pixel_n) begin
            encoder_rgb <= 24'h808080;
            encoder_de <= 1'b0;
            encoder_hsync <= 1'b0;
            encoder_vsync <= 1'b0;
        end else begin
            encoder_rgb <= display_rgb;
            encoder_de <= display_de;
            encoder_hsync <= display_hsync;
            encoder_vsync <= display_vsync;
        end
    end

    // OSD plus the compositor register delay timing by five pixels. Recover
    // the matching coordinate arithmetically instead of spending 110 FFs.
    wire [11:0] encoder_x = (video_x >= 12'd5)
                          ? video_x - 12'd5 : video_x + 12'd1975;
    wire [9:0] encoder_y = (video_x >= 12'd5) ? video_y
                         : (video_y == 0) ? 10'd749 : video_y - 1'b1;

    wire [9:0] tmds_blue, tmds_green, tmds_red;
    receiver_hdmi_tx hdmi_tx (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .x(encoder_x), .y(encoder_y), .rgb(encoder_rgb),
        .data_enable(encoder_de), .hsync(encoder_hsync),
        .vsync(encoder_vsync), .tmds_blue(tmds_blue),
        .tmds_green(tmds_green), .tmds_red(tmds_red)
    );

    receiver_tmds_gearbox5 blue_gearbox (
        .half_pixel_clk(hdmi_half_pixel_clk), .rst_n(reset_half_n),
        .tmds_word(tmds_blue), .serializer_data(hdmi_data0_5b)
    );
    receiver_tmds_gearbox5 green_gearbox (
        .half_pixel_clk(hdmi_half_pixel_clk), .rst_n(reset_half_n),
        .tmds_word(tmds_green), .serializer_data(hdmi_data1_5b)
    );
    receiver_tmds_gearbox5 red_gearbox (
        .half_pixel_clk(hdmi_half_pixel_clk), .rst_n(reset_half_n),
        .tmds_word(tmds_red), .serializer_data(hdmi_data2_5b)
    );

    wire [5:0] led_effective_on =
        (led_auto_on & ~led_override_mask)
        | (led_manual_on & led_override_mask);
    assign LED = ~led_effective_on;

    wire unused_inputs;
    assign unused_inputs = ^{
        CLK_48Mhz, hdmi_fast_clk, link_write_level,
        parser_display_frame_id, parser_source_frame_id,
        parser_quality, parser_fragment_index, parser_fragment_count,
        parser_record_flags, parser_payload_last,
        base_completed_count, base_residual_xor,
        transform_fifo_level, transform_busy,
        lf_busy, lf_completed_count, lf_rejected_count,
        decoded_write_owner,
        enhancement_event_valid, enhancement_event_kind,
        enhancement_event_ctu_index, enhancement_event_block_index,
        enhancement_event_plane, enhancement_event_scan_index,
        enhancement_event_coefficient, enhancement_event_quality,
        enhancement_event_frame_id, enhancement_event_stripe_id,
        enhancement_coefficient_xor,
        enhancement_stored_valid, enhancement_stored_frame_id,
        enhancement_stored_stripe_id, enhancement_stored_count,
        enhancement_store_rejected_count, enhancement_replayed_count,
        enhancement_request_miss_count,
        enhancement_replay_request_ready,
        stripe_displayed_count, stripe_missing_count,
        CSI_PCLK, CSI_VSYNC, CSI_HSYNC, CSI_D
    };
endmodule

/* verilator lint_on DECLFILENAME */
