`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */

module t20f169_receiver (
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
    reg [3:0] reset_60_sync;
    reg [3:0] reset_24_sync;
    reg [3:0] reset_pixel_sync;
    reg [3:0] reset_half_sync;
    wire reset_60_n = reset_60_sync[3];
    wire reset_24_n = reset_24_sync[3];
    wire reset_pixel_n = reset_pixel_sync[3];
    wire reset_half_n = reset_half_sync[3];

    assign pll_reset = 1'b0;
    assign pll2_reset = 1'b0;
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

    wire [10:0] video_x;
    wire [9:0] video_y;
    wire timing_de, timing_hsync, timing_vsync, frame_start;
    receiver_video_timing_720p timing (
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
    wire [12:0] link_write_level;
    wire [12:0] link_read_level;
    wire link_clock_enabled_24;
    wire link_warning_24;
    wire link_overflow_24;
    wire link_framing_24;
    wire link_parser_entry_ready;
    receiver_parallel_ingress parallel_ingress (
        .link_clk(pll_24Mhz), .link_rst_n(reset_24_n),
        .par_clk(PAR_CLK), .par_cs(PAR_CS), .par_data(PAR_D),
        .read_clk(pll_60Mhz), .read_rst_n(reset_60_n),
        .output_entry(link_entry), .output_valid(link_entry_valid),
        .output_ready(link_drain_enable && link_parser_entry_ready),
        .write_level(link_write_level), .read_level(link_read_level),
        .par_clock_enabled(link_clock_enabled_24),
        .warning_level(link_warning_24),
        .overflow_error(link_overflow_24),
        .framing_error(link_framing_24)
    );

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
    wire [31:0] parser_accepted_count, parser_rejected_count;
    wire [31:0] parser_crc_error_count, parser_length_error_count;
    wire [31:0] parser_framing_error_count;
    receiver_link_record_parser link_parser (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .entry(link_entry), .entry_valid(link_entry_valid),
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
        .accepted_count(parser_accepted_count),
        .rejected_count(parser_rejected_count),
        .crc_error_count(parser_crc_error_count),
        .length_error_count(parser_length_error_count),
        .framing_error_count(parser_framing_error_count)
    );

    wire [23:0] stripe_rgb;
    wire stripe_de, stripe_hsync, stripe_vsync;
    wire [31:0] stripe_completed_count, stripe_rejected_count;
    wire [31:0] stripe_displayed_count, stripe_missing_count;
    receiver_yuv420_stripe_buffers stripe_buffers (
        .write_clk(pll_60Mhz), .write_rst_n(reset_60_n),
        .record_valid(parser_record_valid && (parser_record_type == 8'h20)),
        .record_ready(stripe_record_ready),
        .record_type(parser_record_type),
        .display_frame_id(parser_display_frame_id),
        .stripe_id(parser_stripe_id),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(parser_payload_valid && (payload_route == 2'd1)),
        .payload_ready(stripe_payload_ready),
        .payload_last(parser_payload_last),
        .pixel_clk(hdmi_pixel_clk), .pixel_rst_n(reset_pixel_n),
        .x(video_x), .y(video_y), .data_enable(timing_de),
        .hsync(timing_hsync), .vsync(timing_vsync),
        .rgb(stripe_rgb), .data_enable_out(stripe_de),
        .hsync_out(stripe_hsync), .vsync_out(stripe_vsync),
        .completed_stripe_count(stripe_completed_count),
        .rejected_stripe_count(stripe_rejected_count),
        .displayed_stripe_count(stripe_displayed_count),
        .missing_stripe_count(stripe_missing_count)
    );

    // Record metadata and payload replay are separate phases. Latch the
    // selected consumer at the metadata handshake so payload bytes cannot be
    // misrouted when the parser advances to its next internal state.
    reg [1:0] payload_route;
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n) begin
            payload_route <= 2'd0;
        end else begin
            if (parser_record_valid && parser_record_ready) begin
                if (parser_payload_length == 0)
                    payload_route <= 2'd0;
                else if (parser_record_type == 8'h20)
                    payload_route <= 2'd1;
                else if (parser_record_type == 8'h10)
                    payload_route <= 2'd2;
                else
                    payload_route <= 2'd3;
            end
            if (parser_payload_valid && parser_payload_ready
                && parser_payload_last)
                payload_route <= 2'd0;
        end
    end

    assign parser_record_ready = (parser_record_type == 8'h20)
                               ? stripe_record_ready
                               : (parser_record_type == 8'h10)
                               ? base_record_ready : 1'b1;
    assign parser_payload_ready = (payload_route == 2'd1)
                                ? stripe_payload_ready
                                : (payload_route == 2'd2)
                                ? base_payload_ready : 1'b1;

    wire base_block_valid;
    wire [6:0] base_block_ctu_index;
    wire [2:0] base_block_index;
    wire [1:0] base_block_plane, base_block_mode;
    wire [71:0] base_block_coefficients;
    wire base_stripe_done;
    wire [15:0] base_stripe_frame_id;
    wire [7:0] base_completed_stripe_id, base_stripe_quality;
    wire [31:0] base_completed_count, base_rejected_count;
    wire [31:0] base_syntax_error_count;
    receiver_base_entropy_decoder base_entropy_decoder (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .record_valid(parser_record_valid && (parser_record_type == 8'h10)),
        .record_ready(base_record_ready),
        .display_frame_id(parser_display_frame_id),
        .stripe_id(parser_stripe_id), .quality(parser_quality),
        .fragment_index(parser_fragment_index),
        .fragment_count(parser_fragment_count),
        .record_flags(parser_record_flags),
        .payload_length(parser_payload_length),
        .payload_data(parser_payload_data),
        .payload_valid(parser_payload_valid && (payload_route == 2'd2)),
        .payload_ready(base_payload_ready),
        .payload_last(parser_payload_last),
        .block_valid(base_block_valid), .block_ready(1'b1),
        .block_ctu_index(base_block_ctu_index),
        .block_index(base_block_index), .block_plane(base_block_plane),
        .block_mode(base_block_mode),
        .block_coefficients(base_block_coefficients),
        .stripe_done(base_stripe_done),
        .stripe_frame_id(base_stripe_frame_id),
        .completed_stripe_id(base_completed_stripe_id),
        .stripe_quality(base_stripe_quality),
        .completed_stripe_count(base_completed_count),
        .rejected_stripe_count(base_rejected_count),
        .syntax_error_count(base_syntax_error_count)
    );

    // Temporary synthesis-visible sink. The next checkpoint replaces it with
    // inverse quantization/IDCT and prediction, without changing transport.
    reg [11:0] base_coefficient_xor;
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n)
            base_coefficient_xor <= 12'd0;
        else if (base_block_valid)
            base_coefficient_xor <= base_coefficient_xor
                                  ^ base_block_coefficients[11:0]
                                  ^ base_block_coefficients[23:12]
                                  ^ base_block_coefficients[35:24]
                                  ^ base_block_coefficients[47:36]
                                  ^ base_block_coefficients[59:48]
                                  ^ base_block_coefficients[71:60];
    end

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
            if (link_entry_valid && link_drain_enable
                && link_parser_entry_ready) begin
                if (link_entry[9:8] == 2'b10)
                    link_transaction_count <= link_transaction_count + 1'b1;
                else begin
                    link_byte_count <= link_byte_count + 1'b1;
                    link_payload_xor <= link_payload_xor ^ link_entry[7:0];
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
                        | link_framing_sync[1]), osd_clear_busy,
        pll2_lock, pll_lock, hdmi_frame_count[5]
    };

    receiver_spi_osd_control osd_control (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .spi_cs_n(SPI_CS), .spi_sck(SPI_CLK),
        .spi_mosi(SPI_MOSI), .spi_miso(SPI_MISO),
        .pll2_lock(pll2_lock),
        .osd_clear_busy(osd_clear_busy),
        .osd_clear_done(osd_clear_done),
        .osd_clear_request(osd_clear_request),
        .osd_write_valid(osd_write_valid),
        .osd_write_ready(osd_write_ready),
        .osd_write_address(osd_write_address),
        .osd_write_data(osd_write_data),
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
        .parser_accepted_count(parser_accepted_count),
        .parser_rejected_count(parser_rejected_count),
        .parser_crc_error_count(parser_crc_error_count),
        .parser_length_error_count(parser_length_error_count),
        .parser_framing_error_count(parser_framing_error_count),
        .led_auto_on(led_auto_on),
        .led_override_mask(led_override_mask),
        .led_manual_on(led_manual_on),
        .command_error(spi_command_error)
    );

    wire osd_mask;
    wire display_de, display_hsync, display_vsync;
    receiver_osd_framebuffer osd (
        .write_clk(pll_60Mhz), .write_rst_n(reset_60_n),
        .clear_request(osd_clear_request),
        .clear_busy(osd_clear_busy), .clear_done(osd_clear_done),
        .write_valid(osd_write_valid), .write_ready(osd_write_ready),
        .write_address(osd_write_address), .write_data(osd_write_data),
        .pixel_clk(hdmi_pixel_clk), .pixel_rst_n(reset_pixel_n),
        .x(video_x), .y(video_y), .data_enable(timing_de),
        .hsync(timing_hsync), .vsync(timing_vsync),
        .osd_mask(osd_mask), .data_enable_out(display_de),
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
            test_pattern_mode_pixel <= 2'd0;
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

    // Mode zero is the real/raw decoder path. Missing or late stripes are
    // already neutral gray at this point; modes 1..3 remain board diagnostics.
    wire [23:0] base_rgb = (test_pattern_mode_pixel == 2'd0)
                         ? stripe_rgb : test_pattern_rgb;

    wire overlay_active = osd_enable_pixel && !clear_busy_pixel_sync[1];
    wire [23:0] display_rgb = (overlay_active && osd_mask)
                              ? osd_rgb_pixel : base_rgb;

    // Keep compositing and TMDS disparity calculation in separate pipeline
    // stages.  This costs one pixel clock and removes the overlay mux and its
    // control fanout from the encoder's arithmetic critical path.
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

    wire [9:0] tmds_blue, tmds_green, tmds_red;
    receiver_tmds_channel blue_channel (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .video_data(encoder_rgb[7:0]),
        .control_data({encoder_vsync, encoder_hsync}),
        .data_enable(encoder_de), .tmds_word(tmds_blue)
    );
    receiver_tmds_channel green_channel (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .video_data(encoder_rgb[15:8]), .control_data(2'b00),
        .data_enable(encoder_de), .tmds_word(tmds_green)
    );
    receiver_tmds_channel red_channel (
        .pixel_clk(hdmi_pixel_clk), .rst_n(reset_pixel_n),
        .video_data(encoder_rgb[23:16]), .control_data(2'b00),
        .data_enable(encoder_de), .tmds_word(tmds_red)
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
        base_block_ctu_index, base_block_index, base_block_plane,
        base_block_mode, base_stripe_done, base_stripe_frame_id,
        base_completed_stripe_id, base_stripe_quality,
        base_completed_count, base_rejected_count,
        base_syntax_error_count, base_coefficient_xor,
        stripe_de, stripe_hsync, stripe_vsync,
        stripe_completed_count, stripe_rejected_count,
        stripe_displayed_count, stripe_missing_count,
        CSI_PCLK, CSI_VSYNC, CSI_HSYNC, CSI_D
    };
endmodule

/* verilator lint_on DECLFILENAME */
