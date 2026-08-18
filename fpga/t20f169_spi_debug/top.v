`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */

module t20f169_spi_debug (
    input  wire       CLK_48Mhz,

    output wire       pll_reset,
    input  wire       pll_lock,
    input  wire       pll_150Mhz,
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
    reg [3:0] reset_150_sync;
    reg [3:0] reset_24_sync;
    reg [23:0] heartbeat;

    wire reset_150_n = reset_150_sync[3];
    wire reset_24_n = reset_24_sync[3];

    wire       codec_byte_valid;
    wire       codec_byte_ready;
    wire [7:0] codec_byte;
    wire       codec_busy;
    wire       codec_error;
    wire       coefficient_saturated;
    wire       codec_quality24;
    wire [2:0] codec_ctu_index;
    wire       nibble_valid;
    wire       nibble_ready;
    wire [3:0] nibble_data;
    wire       nibble_last;
    wire       fifo_read_valid;
    wire [3:0] fifo_read_data;
    wire       fifo_read_last;

    assign pll_reset = 1'b0;
    assign CSI_MCLK = pll_24Mhz;

    always @(posedge pll_150Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_150_sync <= 4'b0000;
        else
            reset_150_sync <= {reset_150_sync[2:0], 1'b1};
    end

    always @(posedge pll_24Mhz or negedge pll_lock) begin
        if (!pll_lock)
            reset_24_sync <= 4'b0000;
        else
            reset_24_sync <= {reset_24_sync[2:0], 1'b1};
    end

    always @(posedge pll_24Mhz) begin
        if (!reset_24_n)
            heartbeat <= 24'd0;
        else
            heartbeat <= heartbeat + 1'b1;
    end

    custom_codec_synthesis_harness debug_codec (
        .clk(pll_150Mhz),
        .rst_n(reset_150_n),
        .seed_data(CSI_D),
        .seed_control({SPI_CLK, SPI_CS, SPI_MOSI}),
        .m_valid(codec_byte_valid),
        .m_ready(codec_byte_ready),
        .m_byte(codec_byte),
        .busy(codec_busy),
        .fatal_error(codec_error),
        .coefficient_saturated(coefficient_saturated),
        .quality24(codec_quality24),
        .ctu_index(codec_ctu_index)
    );

    byte_to_nibble_last byte_splitter (
        .clk(pll_150Mhz),
        .rst_n(reset_150_n),
        .s_valid(codec_byte_valid),
        .s_ready(codec_byte_ready),
        .s_data(codec_byte),
        .s_last(1'b0),
        .m_valid(nibble_valid),
        .m_ready(nibble_ready),
        .m_data(nibble_data),
        .m_last(nibble_last)
    );

    async_nibble_fifo #(
        .ADDRESS_WIDTH(5)
    ) output_fifo (
        .write_clk(pll_150Mhz),
        .write_rst_n(reset_150_n),
        .write_valid(nibble_valid),
        .write_ready(nibble_ready),
        .write_data(nibble_data),
        .write_last(nibble_last),
        .read_clk(pll_24Mhz),
        .read_rst_n(reset_24_n),
        .read_valid(fifo_read_valid),
        .read_ready(1'b1),
        .read_data(fifo_read_data),
        .read_last(fifo_read_last)
    );

    // PAR_CS is an active-high data-valid signal. ESP32 samples PAR_D on
    // each rising PAR_CLK edge only while PAR_CS is high.
    assign PAR_CLK = pll_24Mhz;
    assign PAR_CS = fifo_read_valid;
    assign PAR_D = fifo_read_data;

    assign LED[0] = heartbeat[23];
    assign LED[1] = pll_lock;
    assign LED[2] = codec_error | coefficient_saturated;
    assign LED[3] = codec_busy;
    assign LED[4] = codec_quality24;
    assign LED[5] = !nibble_ready;

    assign SPI_MISO = codec_error ^ coefficient_saturated
                    ^ codec_quality24 ^ codec_ctu_index[0];

    wire unused_inputs;
    assign unused_inputs = ^{
        CLK_48Mhz, CSI_PCLK, CSI_VSYNC, CSI_HSYNC, fifo_read_last
    };
endmodule
/* verilator lint_on DECLFILENAME */
