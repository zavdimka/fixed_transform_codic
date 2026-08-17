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

    wire       nibble_valid;
    wire       nibble_ready;
    wire [3:0] nibble_data;
    wire       nibble_last;
    wire       fifo_read_valid;
    wire [3:0] fifo_read_data;
    wire       fifo_read_last;

    wire [7:0] debug_status;
    wire [6:0] current_ctu_x;
    wire [5:0] current_ctu_y;
    wire [31:0] nal_byte_count;
    wire debug_error;

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

    hevc_720p_spi_debug_top debug_codec (
        .clk(pll_150Mhz),
        .rst_n(reset_150_n),
        .spi_cs_n(SPI_CS),
        .spi_sck(SPI_CLK),
        .spi_mosi(SPI_MOSI),
        .spi_miso(SPI_MISO),
        .nibble_valid(nibble_valid),
        .nibble_ready(nibble_ready),
        .nibble_data(nibble_data),
        .nibble_last(nibble_last),
        .debug_status(debug_status),
        .current_ctu_x(current_ctu_x),
        .current_ctu_y(current_ctu_y),
        .nal_byte_count(nal_byte_count),
        .debug_error(debug_error)
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
    assign LED[2] = debug_error;
    assign LED[3] = debug_status[5];
    assign LED[4] = debug_status[0];
    assign LED[5] = !nibble_ready;

    wire unused_inputs;
    assign unused_inputs = ^{
        CLK_48Mhz, CSI_PCLK, CSI_VSYNC, CSI_HSYNC, CSI_D,
        fifo_read_last, debug_status, current_ctu_x, current_ctu_y,
        nal_byte_count
    };
endmodule
/* verilator lint_on DECLFILENAME */
