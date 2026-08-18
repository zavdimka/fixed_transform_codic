`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */

module t20f169_spi_debug (
    input  wire       CLK_48Mhz,

    output wire       pll_reset,
    input  wire       pll_lock,
    input  wire       pll_60Mhz,
    input  wire       pll_24Mhz,

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
    wire [2:0] codec_ctu_index;
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

    wire       capture_arm;
    wire       capture_busy;
    wire       capture_done;
    wire       capture_error;
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

    assign pll_reset = 1'b0;
    assign CSI_MCLK = pll_24Mhz;

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

    always @(posedge CSI_PCLK or negedge pll_lock) begin
        if (!pll_lock)
            reset_csi_sync <= 4'b0000;
        else
            reset_csi_sync <= {reset_csi_sync[2:0], 1'b1};
    end

    always @(posedge pll_24Mhz) begin
        if (!reset_24_n)
            heartbeat <= 24'd0;
        else
            heartbeat <= heartbeat + 1'b1;
    end

    custom_codec_synthesis_harness debug_codec (
        .clk(pll_60Mhz),
        .rst_n(reset_60_n),
        .seed_data(CSI_D),
        .seed_control({SPI_CLK, SPI_CS, SPI_MOSI}),
        .source_mode(codec_source_mode),
        .m_valid(codec_byte_valid),
        .m_ready(codec_byte_ready),
        .m_layer(codec_byte_layer),
        .m_byte(codec_byte),
        .packet_commit(codec_packet_commit),
        .busy(codec_busy),
        .fatal_error(codec_error),
        .coefficient_saturated(coefficient_saturated),
        .quality24(codec_quality24),
        .ctu_index(codec_ctu_index)
    );

    layer_packet_pingpong #(
        .MAX_PACKET_BYTES(2048)
    ) output_packets (
        .write_clk(pll_60Mhz),
        .write_rst_n(reset_60_n),
        .s_valid(codec_byte_valid),
        .s_ready(codec_byte_ready),
        .s_data(codec_byte),
        .s_layer(codec_byte_layer),
        .s_commit(codec_packet_commit),
        .s_commit_ready(packet_commit_ready),
        .write_overflow(packet_overflow),
        .read_clk(pll_24Mhz),
        .read_rst_n(reset_24_n),
        .gap_cycles(packet_gap_cycles),
        .packet_active(packet_active),
        .packet_data(packet_data),
        .packet_layer(packet_layer),
        .packet_start(packet_start),
        .packet_end(packet_end),
        .packet_byte_length(packet_byte_length),
        .packet_count(packet_count)
    );

    camera_yuv422_snapshot32 camera_snapshot (
        .pixel_clk(CSI_PCLK),
        .pixel_rst_n(reset_csi_n),
        .pixel_vsync(CSI_VSYNC),
        .pixel_href(CSI_HSYNC),
        .pixel_data(CSI_D),
        .read_clk(pll_60Mhz),
        .read_rst_n(reset_60_n),
        .arm(capture_arm),
        .vsync_active_high(capture_vsync_active_high),
        .href_active_high(capture_href_active_high),
        .capture_busy(capture_busy),
        .capture_done(capture_done),
        .capture_error(capture_error),
        .captured_lines(captured_lines),
        .last_line_bytes(captured_last_line_bytes),
        .captured_words(captured_words),
        .read_request(snapshot_read_request),
        .read_word_address(snapshot_read_address),
        .read_valid(snapshot_read_valid),
        .read_word(snapshot_read_word)
    );

    custom_spi_debug_control debug_control (
        .clk(pll_60Mhz), .rst_n(reset_60_n),
        .spi_cs_n(SPI_CS), .spi_sck(SPI_CLK),
        .spi_mosi(SPI_MOSI), .spi_miso(SPI_MISO),
        .codec_busy(codec_busy), .codec_error(codec_error),
        .coefficient_saturated(coefficient_saturated),
        .packet_overflow(packet_overflow),
        .packet_active(packet_active), .packet_layer(packet_layer),
        .packet_byte_length(packet_byte_length),
        .packet_count(packet_count), .quality24(codec_quality24),
        .ctu_index(codec_ctu_index), .gap_cycles(packet_gap_cycles),
        .source_mode(codec_source_mode),
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

    // PAR_CS is an active-high data-valid signal. ESP32 samples PAR_D on
    // each rising PAR_CLK edge only while PAR_CS is high.
    assign PAR_CLK = pll_24Mhz;
    assign PAR_CS = packet_active;
    assign PAR_D = packet_data;

    assign LED[0] = heartbeat[23];
    assign LED[1] = pll_lock;
    assign LED[2] = codec_error | coefficient_saturated
                  | packet_overflow | spi_command_error;
    assign LED[3] = codec_busy;
    assign LED[4] = codec_quality24;
    assign LED[5] = capture_busy | capture_error;

    wire unused_inputs;
    assign unused_inputs = ^{
        CLK_48Mhz, packet_start, packet_end, packet_commit_ready
    };
endmodule
/* verilator lint_on DECLFILENAME */
