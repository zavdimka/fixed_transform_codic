`timescale 1ns/1ps

module t20f169_spi_debug (
// ref clock input
    input  wire CLK_48Mhz,
//  PLL IO
    output wire pll_reset,
    input  wire pll_lock,
    input  pll_150Mhz,
    input  pll_24Mhz,
//SPI IO
    input wire SPI_CLK,
    input wire SPI_CS,
    input wire SPI_MOSI,
    output wire SPI_MISO,
//PAR bus to ESP32C5
    output wire PAR_CS,
    output wire PAR_CLK,
    output wire [3:0]PAR_D,
//LED test bus indication
    output wire [5:0]LED,
    
// CSI IO
    output wire CSI_MCLK,
    input  wire CSI_PCLK,
    input  wire CSI_VSYNC,
    input  wire CSI_HSYNC,
    input  wire[7:0] CSI_D
    
    
);

    reg [25:0] counter;

    always @(posedge pll_150Mhz) begin
            counter <= counter + 1'b1;
    end

    assign LED[0] = counter[24];
    assign SPI_MISO = counter[22];

endmodule