`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */

module t20f169_spi_debug (
    input  wire       CLK_48Mhz,

    output wire       pll_reset,
    input  wire       pll_lock,
    input  wire       pll_60Mhz,
    input  wire       pll_24Mhz,

    output wire       pll2_reset,
    input  wire       pll2_lock,
    input  wire       hdmi_fast_clk,
    input  wire       hdmi_half_pixel_clk,
    output wire [4:0] hdmi_data0_5b,
    output wire [4:0] hdmi_data1_5b,
    output wire [4:0] hdmi_data2_5b,

    input  wire       SPI_CLK,
    input  wire       SPI_CS,
    input  wire       SPI_MOSI,
    output wire       SPI_MISO,

    output wire       PAR_CS,
    output wire       PAR_CLK,
    output wire [3:0] PAR_D,

    output wire [5:0] LED,

    output wire       CSI_MCLK,
    input  wire       CSI_PCLK,
    input  wire       CSI_VSYNC,
    input  wire       CSI_HSYNC,
    input  wire [7:0] CSI_D
);
    reg [3:0] reset_60_sync;
    reg [3:0] reset_24_sync;
    reg [3:0] reset_csi_sync;
    reg [23:0] heartbeat;
    reg [1:0] csi_mclk_divider;

    wire reset_60_n = reset_60_sync[3];
    wire reset_24_n = reset_24_sync[3];
    wire reset_csi_n = reset_csi_sync[3];

    wire       codec_byte_valid;
    wire       codec_byte_ready;
    wire       codec_byte_layer;
    wire [7:0] codec_byte;
    wire       codec_packet_commit;
    wire       codec_busy;
    wire       codec_error;
    wire       coefficient_saturated;
    wire       codec_quality24;
    wire [6:0] codec_ctu_index;
    wire [3:0] codec_debug_state;
    wire [6:0] codec_completed_ctus;
    wire [7:0] codec_debug_handshake;
    wire       packet_overflow;
    wire       packet_commit_ready;
    wire       packet_active;
    wire [3:0] packet_data;
    wire       packet_layer;
    wire       packet_start;
    wire       packet_end;
    wire [15:0] packet_byte_length;
    wire [31:0] packet_count;
    wire [15:0] packet_gap_cycles;
    wire [1:0]  codec_source_mode;
    wire        configured_quality24;
    wire        camera_stripe_valid;
    wire        camera_stripe_take;
    wire [15:0] camera_frame_id;
    wire [5:0]  camera_stripe_index;
    wire [6:0]  camera_read_ctu;
    wire        camera_read_ctu_start;
    wire        camera_row_valid;
    wire        camera_row_ready;
    wire [5:0]  camera_row_index;
    wire [127:0] camera_row_data;
    wire        camera_stripe_release;
    wire        camera_overflow;
    wire [15:0] camera_dropped_stripes;
    wire [15:0] codec_frame_id;
    wire [5:0]  codec_stripe_index;
    wire [7:0]  codec_quality;
    wire [16:0] codec_base_bits;
    wire [16:0] codec_enhancement_bits;
    wire       packet_source_valid;
    wire       packet_source_ready;
    wire       packet_source_layer;
    wire [7:0] packet_source_data;
    wire       packet_source_commit;
    wire       packet_source_commit_ready;
    wire [15:0] packet_source_frame_id;
    wire [5:0]  packet_source_stripe_index;
    wire [7:0]  packet_source_quality;
    wire [16:0] packet_source_base_bits;
    wire [16:0] packet_source_enhancement_bits;

`ifdef PARLIO_LINK_SELFTEST
    wire [15:0] link_test_record_index;
    parlio_link_test_producer link_test_source (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .s_valid(packet_source_valid), .s_ready(packet_source_ready),
        .s_data(packet_source_data), .s_layer(packet_source_layer),
        .s_commit(packet_source_commit),
        .s_commit_ready(packet_source_commit_ready),
        .frame_id(packet_source_frame_id),
        .stripe_index(packet_source_stripe_index),
        .quality(packet_source_quality),
        .base_bits(packet_source_base_bits),
        .enhancement_bits(packet_source_enhancement_bits),
        .record_index(link_test_record_index)
    );
    assign codec_byte_ready = 1'b0;
    assign packet_commit_ready = 1'b0;
`else
    assign packet_source_valid = codec_byte_valid;
    assign packet_source_layer = codec_byte_layer;
    assign packet_source_data = codec_byte;
    assign packet_source_commit = codec_packet_commit;
    assign packet_source_frame_id = codec_frame_id;
    assign packet_source_stripe_index = codec_stripe_index;
    assign packet_source_quality = codec_quality;
    assign packet_source_base_bits = codec_base_bits;
    assign packet_source_enhancement_bits = codec_enhancement_bits;
    assign codec_byte_ready = packet_source_ready;
    assign packet_commit_ready = packet_source_commit_ready;
`endif

    wire       capture_arm;
    wire       capture_busy;
    wire       capture_done;
    wire       capture_error;
    wire       snapshot_capture_error;
    reg        stream_armed_60;
    (* async_reg = "true" *) reg stream_arm_sync_1;
    (* async_reg = "true" *) reg stream_arm_sync_2;
    wire       capture_vsync_active_high;
    wire       capture_href_active_high;
    wire [15:0] captured_lines;
    wire [15:0] captured_last_line_bytes;
    wire [14:0] captured_words;
    wire       snapshot_read_request;
    wire [13:0] snapshot_read_address;
    wire       snapshot_read_valid;
    wire [39:0] snapshot_read_word;
    wire       spi_command_error;
    wire [5:0] led_auto_on;
    wire [5:0] led_override_mask;
    wire [5:0] led_manual_on;
    wire [5:0] led_effective_on;

    // Efinity PLL RSTN is active-low; high enables the codec PLL.
    assign pll_reset = 1'b1;
    // The transmitter image does not use HDMI. Hold its active-low RSTN
    // asserted and feed deterministic values to the serializer inputs.
    assign pll2_reset = 1'b0;
    assign hdmi_data0_5b = 5'b00000;
    assign hdmi_data1_5b = 5'b00000;
    assign hdmi_data2_5b = 5'b00000;
    // 16.5 MHz camera MCLK from the 66 MHz codec PLL. CSI data and sync are
    // sampled on falling PCLK and aligned on rising PCLK in the fabric.
    assign CSI_MCLK = csi_mclk_divider[1];

    always @(posedge pll_60Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_60_sync <= 4'b0000;
        else
            reset_60_sync <= {reset_60_sync[2:0], 1'b1};
    end

    always @(posedge pll_60Mhz) begin
        if (!reset_60_n)
            csi_mclk_divider <= 2'b00;
        else
            csi_mclk_divider <= csi_mclk_divider + 1'b1;
    end

    always @(posedge pll_24Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_24_sync <= 4'b0000;
        else
            reset_24_sync <= {reset_24_sync[2:0], 1'b1};
    end

    always @(posedge CSI_PCLK or negedge pll_lock) begin
        if (!pll_lock)
            reset_csi_sync <= 4'b0000;
        else
            reset_csi_sync <= {reset_csi_sync[2:0], 1'b1};
    end

    // Hold the packetizer read side in reset until ESP32 has queued every DMA
    // buffer and explicitly arms the capture. The codec may fill both banks
    // while waiting; backpressure then preserves them without emitting data.
    always @(posedge pll_60Mhz) begin
        if (!reset_60_n)
            stream_armed_60 <= 1'b0;
        else if (capture_arm)
            stream_armed_60 <= 1'b1;
    end

    always @(posedge pll_24Mhz) begin
        if (!reset_24_n) begin
            stream_arm_sync_1 <= 1'b0;
            stream_arm_sync_2 <= 1'b0;
        end else begin
            stream_arm_sync_1 <= stream_armed_60;
            stream_arm_sync_2 <= stream_arm_sync_1;
        end
    end

    always @(posedge pll_24Mhz) begin
        if (!reset_24_n) begin
            heartbeat <= 24'd0;
        end else begin
            heartbeat <= heartbeat + 1'b1;
        end
    end

    camera_yuv422_stripe_buffer8way camera_stripes (
        .pixel_clk(CSI_PCLK), .pixel_rst_n(reset_csi_n),
        .pixel_vsync(CSI_VSYNC), .pixel_href(CSI_HSYNC),
        .pixel_data(CSI_D),
        .read_clk(pll_60Mhz), .read_rst_n(reset_60_n),
        .stripe_valid(camera_stripe_valid),
        .stripe_take(camera_stripe_take),
        .stripe_frame_id(camera_frame_id),
        .stripe_index(camera_stripe_index),
        .read_ctu(camera_read_ctu),
        .read_ctu_start(camera_read_ctu_start),
        .row_ready(camera_row_ready), .row_valid(camera_row_valid),
        .row_index(camera_row_index), .row_data(camera_row_data),
        .stripe_release(camera_stripe_release),
        .overflow(camera_overflow),
        .dropped_stripes(camera_dropped_stripes)
    );

    custom_camera_codec_pipeline camera_codec (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .configured_quality24(configured_quality24),
        .stripe_valid(camera_stripe_valid),
        .stripe_take(camera_stripe_take),
        .stripe_frame_id(camera_frame_id),
        .stripe_index(camera_stripe_index),
        .read_ctu(camera_read_ctu),
        .read_ctu_start(camera_read_ctu_start),
        .row_valid(camera_row_valid), .row_ready(camera_row_ready),
        .row_index(camera_row_index), .row_data(camera_row_data),
        .stripe_release(camera_stripe_release),
        .m_valid(codec_byte_valid), .m_ready(codec_byte_ready),
        .m_layer(codec_byte_layer), .m_byte(codec_byte),
        .packet_commit(codec_packet_commit),
        .packet_commit_ready(packet_commit_ready),
        .packet_frame_id(codec_frame_id),
        .packet_stripe_index(codec_stripe_index),
        .packet_quality(codec_quality),
        .packet_base_bits(codec_base_bits),
        .packet_enhancement_bits(codec_enhancement_bits),
        .busy(codec_busy), .fatal_error(codec_error),
        .coefficient_saturated(coefficient_saturated),
        .ctu_index(codec_ctu_index),
        .debug_state(codec_debug_state),
        .debug_completed_ctus(codec_completed_ctus),
        .debug_handshake(codec_debug_handshake)
    );

    assign codec_quality24 = codec_quality == 24;

    link_record_packetizer #(
        .MAX_LAYER_BYTES(2048), .FRAGMENT_BYTES(1400),
        .WIRE_RECORD_BYTES(1420)
    ) output_packets (
        .write_clk(pll_60Mhz),
        .write_rst_n(reset_60_n),
        .s_valid(packet_source_valid),
        .s_ready(packet_source_ready),
        .s_data(packet_source_data),
        .s_layer(packet_source_layer),
        .s_commit(packet_source_commit),
        .s_commit_ready(packet_source_commit_ready),
        .s_frame_id(packet_source_frame_id),
        .s_stripe_index(packet_source_stripe_index),
        .s_quality(packet_source_quality),
        .s_base_bits(packet_source_base_bits),
        .s_enhancement_bits(packet_source_enhancement_bits),
        .write_overflow(packet_overflow),
        .read_clk(pll_24Mhz),
        .read_rst_n(reset_24_n && stream_arm_sync_2),
        .read_enable(1'b1),
        .gap_cycles(packet_gap_cycles),
        .packet_active(packet_active),
        .packet_data(packet_data),
        .packet_layer(packet_layer),
        .packet_start(packet_start),
        .packet_end(packet_end),
        .packet_byte_length(packet_byte_length),
        .packet_count(packet_count)
    );

    camera_dvp_sample64 camera_sample (
        .pixel_clk(CSI_PCLK), .pixel_rst_n(reset_csi_n),
        .pixel_vsync(CSI_VSYNC), .pixel_href(CSI_HSYNC),
        .pixel_data(CSI_D),
        .read_clk(pll_60Mhz), .read_rst_n(reset_60_n),
        .arm(capture_arm),
        .vsync_active_high(capture_vsync_active_high),
        .href_active_high(capture_href_active_high),
        .capture_busy(capture_busy), .capture_done(capture_done),
        .capture_error(snapshot_capture_error),
        .captured_lines(captured_lines),
        .last_line_bytes(captured_last_line_bytes),
        .captured_words(captured_words),
        .read_request(snapshot_read_request),
        .read_word_address(snapshot_read_address),
        .read_valid(snapshot_read_valid),
        .read_word(snapshot_read_word)
    );
    assign capture_error = snapshot_capture_error | camera_overflow;

    custom_spi_debug_control debug_control (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .spi_cs_n(SPI_CS), .spi_sck(SPI_CLK),
        .spi_mosi(SPI_MOSI), .spi_miso(SPI_MISO),
        .codec_busy(codec_busy), .codec_error(codec_error),
        .coefficient_saturated(coefficient_saturated),
        .packet_overflow(packet_overflow),
        .packet_active(packet_active), .packet_layer(packet_layer),
        .packet_byte_length(packet_byte_length),
        .packet_count(packet_count),
        .camera_frame_id(camera_frame_id),
        .camera_dropped_stripes(camera_dropped_stripes),
        .quality24(codec_quality24),
        .ctu_index(codec_ctu_index[2:0]),
        .debug_ctu_index(codec_ctu_index),
        .debug_state(codec_debug_state),
        .debug_completed_ctus(codec_completed_ctus),
        .debug_handshake(codec_debug_handshake),
        .gap_cycles(packet_gap_cycles),
        .source_mode(codec_source_mode),
        .configured_quality24(configured_quality24),
        .led_auto_on(led_auto_on),
        .led_override_mask(led_override_mask),
        .led_manual_on(led_manual_on),
        .capture_arm(capture_arm),
        .vsync_active_high(capture_vsync_active_high),
        .href_active_high(capture_href_active_high),
        .capture_busy(capture_busy), .capture_done(capture_done),
        .capture_error(capture_error), .captured_lines(captured_lines),
        .last_line_bytes(captured_last_line_bytes),
        .captured_words(captured_words),
        .snapshot_read_request(snapshot_read_request),
        .snapshot_read_address(snapshot_read_address),
        .snapshot_read_valid(snapshot_read_valid),
        .snapshot_read_word(snapshot_read_word),
        .command_error(spi_command_error)
    );

    // Keep the 24 MHz external receive clock running continuously. Data advances
    // on each internal rising edge and is sampled 20.8 ns later on PAR_CLK.
    // Continuous clocks while CS is low let ESP32 PARLIO observe the
    // level-delimiter transition and close DMA exactly at the record boundary.
    assign PAR_CLK = ~pll_24Mhz;
    assign PAR_CS = packet_active;
    assign PAR_D = packet_data;

    // Logical LED state is active high everywhere inside the design.  Only
    // this final assignment accounts for the board's active-low LED wiring.
    assign led_auto_on[0] = heartbeat[23];
    assign led_auto_on[1] = pll_lock;
    assign led_auto_on[2] = codec_error | coefficient_saturated
                          | packet_overflow | spi_command_error
                          | capture_error;
    assign led_auto_on[3] = codec_busy;
    assign led_auto_on[4] = codec_quality24;
    assign led_auto_on[5] = capture_busy;
    assign led_effective_on = (led_auto_on & ~led_override_mask)
                            | (led_manual_on & led_override_mask);
    assign LED = ~led_effective_on;

    wire unused_inputs;
    assign unused_inputs = ^{
        CLK_48Mhz, pll2_lock, hdmi_fast_clk, hdmi_half_pixel_clk,
        packet_start, packet_end, packet_commit_ready
    };
endmodule
/* verilator lint_on DECLFILENAME */
