
//
// Verific Verilog Description of module t20f169_spi_debug
//

module t20f169_spi_debug (CLK_48Mhz, pll_reset, pll_lock, pll_150Mhz, 
            pll_24Mhz, SPI_CLK, SPI_CS, SPI_MOSI, SPI_MISO, PAR_CS, 
            PAR_CLK, PAR_D, LED, CSI_MCLK, CSI_PCLK, CSI_VSYNC, 
            CSI_HSYNC, CSI_D) /* verific EFX_ATTRIBUTE_NETLIST__EFINITY_VERSION=2026.1.132 */ ;
    input CLK_48Mhz /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(5)
    output pll_reset /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(7)
    input pll_lock /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(8)
    input pll_150Mhz /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(9)
    input pll_24Mhz /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(10)
    input SPI_CLK /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(12)
    input SPI_CS /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(13)
    input SPI_MOSI /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(14)
    output SPI_MISO /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(15)
    output PAR_CS /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(17)
    output PAR_CLK /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(18)
    output [3:0]PAR_D /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(19)
    output [5:0]LED /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    output CSI_MCLK /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(24)
    input CSI_PCLK /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(25)
    input CSI_VSYNC /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(26)
    input CSI_HSYNC /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(27)
    input [7:0]CSI_D /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_INPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(28)
    
    wire [25:0]n6;
    
    wire \add_22/n30 , \add_22/n26 , \add_22/n24 , \add_22/n22 , \add_22/n32 , 
        \add_22/n20 ;
    wire [25:0]counter;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(33)
    
    wire \add_22/n18 , \add_22/n16 , \add_22/n14 , \add_22/n12 , \add_22/n10 , 
        \add_22/n8 , \add_22/n6 , \add_22/n4 , \add_22/n2 , \add_22/n28 , 
        \add_22/n34 , \add_22/n36 , \add_22/n38 , \add_22/n40 , \add_22/n42 , 
        \add_22/n44 , \add_22/n46 , \pll_150Mhz~O ;
    
    assign PAR_CS = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(17)
    assign PAR_CLK = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(18)
    assign PAR_D[3] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(19)
    assign PAR_D[2] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(19)
    assign PAR_D[1] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(19)
    assign PAR_D[0] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(19)
    assign LED[5] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    assign LED[4] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    assign LED[3] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    assign LED[2] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    assign LED[1] = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(21)
    assign CSI_MCLK = 1'b0 /* verific EFX_ATTRIBUTE_PORT__IS_PRIMARY_OUTPUT=TRUE */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(24)
    assign pll_reset = 1'b0 /* verific EFX_ATTRIBUTE_CELL_NAME=GND */ ;
    EFX_FF \counter[1]~FF  (.D(n6[1]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[1])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[1]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[1]~FF .CE_POLARITY = 1'b1;
    defparam \counter[1]~FF .SR_POLARITY = 1'b1;
    defparam \counter[1]~FF .D_POLARITY = 1'b1;
    defparam \counter[1]~FF .SR_SYNC = 1'b1;
    defparam \counter[1]~FF .SR_VALUE = 1'b0;
    defparam \counter[1]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[0]~FF  (.D(counter[0]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[0])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b0, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[0]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[0]~FF .CE_POLARITY = 1'b1;
    defparam \counter[0]~FF .SR_POLARITY = 1'b1;
    defparam \counter[0]~FF .D_POLARITY = 1'b0;
    defparam \counter[0]~FF .SR_SYNC = 1'b1;
    defparam \counter[0]~FF .SR_VALUE = 1'b0;
    defparam \counter[0]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[2]~FF  (.D(n6[2]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[2])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[2]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[2]~FF .CE_POLARITY = 1'b1;
    defparam \counter[2]~FF .SR_POLARITY = 1'b1;
    defparam \counter[2]~FF .D_POLARITY = 1'b1;
    defparam \counter[2]~FF .SR_SYNC = 1'b1;
    defparam \counter[2]~FF .SR_VALUE = 1'b0;
    defparam \counter[2]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[3]~FF  (.D(n6[3]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[3])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[3]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[3]~FF .CE_POLARITY = 1'b1;
    defparam \counter[3]~FF .SR_POLARITY = 1'b1;
    defparam \counter[3]~FF .D_POLARITY = 1'b1;
    defparam \counter[3]~FF .SR_SYNC = 1'b1;
    defparam \counter[3]~FF .SR_VALUE = 1'b0;
    defparam \counter[3]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[4]~FF  (.D(n6[4]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[4])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[4]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[4]~FF .CE_POLARITY = 1'b1;
    defparam \counter[4]~FF .SR_POLARITY = 1'b1;
    defparam \counter[4]~FF .D_POLARITY = 1'b1;
    defparam \counter[4]~FF .SR_SYNC = 1'b1;
    defparam \counter[4]~FF .SR_VALUE = 1'b0;
    defparam \counter[4]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[5]~FF  (.D(n6[5]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[5])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[5]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[5]~FF .CE_POLARITY = 1'b1;
    defparam \counter[5]~FF .SR_POLARITY = 1'b1;
    defparam \counter[5]~FF .D_POLARITY = 1'b1;
    defparam \counter[5]~FF .SR_SYNC = 1'b1;
    defparam \counter[5]~FF .SR_VALUE = 1'b0;
    defparam \counter[5]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[6]~FF  (.D(n6[6]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[6])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[6]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[6]~FF .CE_POLARITY = 1'b1;
    defparam \counter[6]~FF .SR_POLARITY = 1'b1;
    defparam \counter[6]~FF .D_POLARITY = 1'b1;
    defparam \counter[6]~FF .SR_SYNC = 1'b1;
    defparam \counter[6]~FF .SR_VALUE = 1'b0;
    defparam \counter[6]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[7]~FF  (.D(n6[7]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[7])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[7]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[7]~FF .CE_POLARITY = 1'b1;
    defparam \counter[7]~FF .SR_POLARITY = 1'b1;
    defparam \counter[7]~FF .D_POLARITY = 1'b1;
    defparam \counter[7]~FF .SR_SYNC = 1'b1;
    defparam \counter[7]~FF .SR_VALUE = 1'b0;
    defparam \counter[7]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[8]~FF  (.D(n6[8]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[8])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[8]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[8]~FF .CE_POLARITY = 1'b1;
    defparam \counter[8]~FF .SR_POLARITY = 1'b1;
    defparam \counter[8]~FF .D_POLARITY = 1'b1;
    defparam \counter[8]~FF .SR_SYNC = 1'b1;
    defparam \counter[8]~FF .SR_VALUE = 1'b0;
    defparam \counter[8]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[9]~FF  (.D(n6[9]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[9])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[9]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[9]~FF .CE_POLARITY = 1'b1;
    defparam \counter[9]~FF .SR_POLARITY = 1'b1;
    defparam \counter[9]~FF .D_POLARITY = 1'b1;
    defparam \counter[9]~FF .SR_SYNC = 1'b1;
    defparam \counter[9]~FF .SR_VALUE = 1'b0;
    defparam \counter[9]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[10]~FF  (.D(n6[10]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[10])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[10]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[10]~FF .CE_POLARITY = 1'b1;
    defparam \counter[10]~FF .SR_POLARITY = 1'b1;
    defparam \counter[10]~FF .D_POLARITY = 1'b1;
    defparam \counter[10]~FF .SR_SYNC = 1'b1;
    defparam \counter[10]~FF .SR_VALUE = 1'b0;
    defparam \counter[10]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[11]~FF  (.D(n6[11]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[11])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[11]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[11]~FF .CE_POLARITY = 1'b1;
    defparam \counter[11]~FF .SR_POLARITY = 1'b1;
    defparam \counter[11]~FF .D_POLARITY = 1'b1;
    defparam \counter[11]~FF .SR_SYNC = 1'b1;
    defparam \counter[11]~FF .SR_VALUE = 1'b0;
    defparam \counter[11]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[12]~FF  (.D(n6[12]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[12])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[12]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[12]~FF .CE_POLARITY = 1'b1;
    defparam \counter[12]~FF .SR_POLARITY = 1'b1;
    defparam \counter[12]~FF .D_POLARITY = 1'b1;
    defparam \counter[12]~FF .SR_SYNC = 1'b1;
    defparam \counter[12]~FF .SR_VALUE = 1'b0;
    defparam \counter[12]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[13]~FF  (.D(n6[13]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[13])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[13]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[13]~FF .CE_POLARITY = 1'b1;
    defparam \counter[13]~FF .SR_POLARITY = 1'b1;
    defparam \counter[13]~FF .D_POLARITY = 1'b1;
    defparam \counter[13]~FF .SR_SYNC = 1'b1;
    defparam \counter[13]~FF .SR_VALUE = 1'b0;
    defparam \counter[13]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[14]~FF  (.D(n6[14]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[14])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[14]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[14]~FF .CE_POLARITY = 1'b1;
    defparam \counter[14]~FF .SR_POLARITY = 1'b1;
    defparam \counter[14]~FF .D_POLARITY = 1'b1;
    defparam \counter[14]~FF .SR_SYNC = 1'b1;
    defparam \counter[14]~FF .SR_VALUE = 1'b0;
    defparam \counter[14]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[15]~FF  (.D(n6[15]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[15])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[15]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[15]~FF .CE_POLARITY = 1'b1;
    defparam \counter[15]~FF .SR_POLARITY = 1'b1;
    defparam \counter[15]~FF .D_POLARITY = 1'b1;
    defparam \counter[15]~FF .SR_SYNC = 1'b1;
    defparam \counter[15]~FF .SR_VALUE = 1'b0;
    defparam \counter[15]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[16]~FF  (.D(n6[16]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[16])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[16]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[16]~FF .CE_POLARITY = 1'b1;
    defparam \counter[16]~FF .SR_POLARITY = 1'b1;
    defparam \counter[16]~FF .D_POLARITY = 1'b1;
    defparam \counter[16]~FF .SR_SYNC = 1'b1;
    defparam \counter[16]~FF .SR_VALUE = 1'b0;
    defparam \counter[16]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[17]~FF  (.D(n6[17]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[17])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[17]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[17]~FF .CE_POLARITY = 1'b1;
    defparam \counter[17]~FF .SR_POLARITY = 1'b1;
    defparam \counter[17]~FF .D_POLARITY = 1'b1;
    defparam \counter[17]~FF .SR_SYNC = 1'b1;
    defparam \counter[17]~FF .SR_VALUE = 1'b0;
    defparam \counter[17]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[18]~FF  (.D(n6[18]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[18])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[18]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[18]~FF .CE_POLARITY = 1'b1;
    defparam \counter[18]~FF .SR_POLARITY = 1'b1;
    defparam \counter[18]~FF .D_POLARITY = 1'b1;
    defparam \counter[18]~FF .SR_SYNC = 1'b1;
    defparam \counter[18]~FF .SR_VALUE = 1'b0;
    defparam \counter[18]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[19]~FF  (.D(n6[19]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[19])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[19]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[19]~FF .CE_POLARITY = 1'b1;
    defparam \counter[19]~FF .SR_POLARITY = 1'b1;
    defparam \counter[19]~FF .D_POLARITY = 1'b1;
    defparam \counter[19]~FF .SR_SYNC = 1'b1;
    defparam \counter[19]~FF .SR_VALUE = 1'b0;
    defparam \counter[19]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[20]~FF  (.D(n6[20]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[20])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[20]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[20]~FF .CE_POLARITY = 1'b1;
    defparam \counter[20]~FF .SR_POLARITY = 1'b1;
    defparam \counter[20]~FF .D_POLARITY = 1'b1;
    defparam \counter[20]~FF .SR_SYNC = 1'b1;
    defparam \counter[20]~FF .SR_VALUE = 1'b0;
    defparam \counter[20]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[21]~FF  (.D(n6[21]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[21])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[21]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[21]~FF .CE_POLARITY = 1'b1;
    defparam \counter[21]~FF .SR_POLARITY = 1'b1;
    defparam \counter[21]~FF .D_POLARITY = 1'b1;
    defparam \counter[21]~FF .SR_SYNC = 1'b1;
    defparam \counter[21]~FF .SR_VALUE = 1'b0;
    defparam \counter[21]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \SPI_MISO~FF  (.D(n6[22]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(SPI_MISO)) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \SPI_MISO~FF .CLK_POLARITY = 1'b1;
    defparam \SPI_MISO~FF .CE_POLARITY = 1'b1;
    defparam \SPI_MISO~FF .SR_POLARITY = 1'b1;
    defparam \SPI_MISO~FF .D_POLARITY = 1'b1;
    defparam \SPI_MISO~FF .SR_SYNC = 1'b1;
    defparam \SPI_MISO~FF .SR_VALUE = 1'b0;
    defparam \SPI_MISO~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \counter[23]~FF  (.D(n6[23]), .CE(1'b1), .CLK(\pll_150Mhz~O ), 
           .SR(1'b0), .Q(counter[23])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \counter[23]~FF .CLK_POLARITY = 1'b1;
    defparam \counter[23]~FF .CE_POLARITY = 1'b1;
    defparam \counter[23]~FF .SR_POLARITY = 1'b1;
    defparam \counter[23]~FF .D_POLARITY = 1'b1;
    defparam \counter[23]~FF .SR_SYNC = 1'b1;
    defparam \counter[23]~FF .SR_VALUE = 1'b0;
    defparam \counter[23]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_FF \LED[0]~FF  (.D(n6[24]), .CE(1'b1), .CLK(\pll_150Mhz~O ), .SR(1'b0), 
           .Q(LED[0])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_FF, CLK_POLARITY=1'b1, D_POLARITY=1'b1, CE_POLARITY=1'b1, SR_SYNC=1'b1, SR_SYNC_PRIORITY=1'b1, SR_VALUE=1'b0, SR_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(37)
    defparam \LED[0]~FF .CLK_POLARITY = 1'b1;
    defparam \LED[0]~FF .CE_POLARITY = 1'b1;
    defparam \LED[0]~FF .SR_POLARITY = 1'b1;
    defparam \LED[0]~FF .D_POLARITY = 1'b1;
    defparam \LED[0]~FF .SR_SYNC = 1'b1;
    defparam \LED[0]~FF .SR_VALUE = 1'b0;
    defparam \LED[0]~FF .SR_SYNC_PRIORITY = 1'b1;
    EFX_ADD \add_22/i15  (.I0(counter[15]), .I1(1'b0), .CI(\add_22/n28 ), 
            .O(n6[15]), .CO(\add_22/n30 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i15 .I0_POLARITY = 1'b1;
    defparam \add_22/i15 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i13  (.I0(counter[13]), .I1(1'b0), .CI(\add_22/n24 ), 
            .O(n6[13]), .CO(\add_22/n26 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i13 .I0_POLARITY = 1'b1;
    defparam \add_22/i13 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i12  (.I0(counter[12]), .I1(1'b0), .CI(\add_22/n22 ), 
            .O(n6[12]), .CO(\add_22/n24 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i12 .I0_POLARITY = 1'b1;
    defparam \add_22/i12 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i11  (.I0(counter[11]), .I1(1'b0), .CI(\add_22/n20 ), 
            .O(n6[11]), .CO(\add_22/n22 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i11 .I0_POLARITY = 1'b1;
    defparam \add_22/i11 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i16  (.I0(counter[16]), .I1(1'b0), .CI(\add_22/n30 ), 
            .O(n6[16]), .CO(\add_22/n32 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i16 .I0_POLARITY = 1'b1;
    defparam \add_22/i16 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i10  (.I0(counter[10]), .I1(1'b0), .CI(\add_22/n18 ), 
            .O(n6[10]), .CO(\add_22/n20 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i10 .I0_POLARITY = 1'b1;
    defparam \add_22/i10 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i9  (.I0(counter[9]), .I1(1'b0), .CI(\add_22/n16 ), 
            .O(n6[9]), .CO(\add_22/n18 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i9 .I0_POLARITY = 1'b1;
    defparam \add_22/i9 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i8  (.I0(counter[8]), .I1(1'b0), .CI(\add_22/n14 ), 
            .O(n6[8]), .CO(\add_22/n16 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i8 .I0_POLARITY = 1'b1;
    defparam \add_22/i8 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i7  (.I0(counter[7]), .I1(1'b0), .CI(\add_22/n12 ), 
            .O(n6[7]), .CO(\add_22/n14 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i7 .I0_POLARITY = 1'b1;
    defparam \add_22/i7 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i6  (.I0(counter[6]), .I1(1'b0), .CI(\add_22/n10 ), 
            .O(n6[6]), .CO(\add_22/n12 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i6 .I0_POLARITY = 1'b1;
    defparam \add_22/i6 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i5  (.I0(counter[5]), .I1(1'b0), .CI(\add_22/n8 ), 
            .O(n6[5]), .CO(\add_22/n10 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i5 .I0_POLARITY = 1'b1;
    defparam \add_22/i5 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i4  (.I0(counter[4]), .I1(1'b0), .CI(\add_22/n6 ), 
            .O(n6[4]), .CO(\add_22/n8 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i4 .I0_POLARITY = 1'b1;
    defparam \add_22/i4 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i3  (.I0(counter[3]), .I1(1'b0), .CI(\add_22/n4 ), 
            .O(n6[3]), .CO(\add_22/n6 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i3 .I0_POLARITY = 1'b1;
    defparam \add_22/i3 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i2  (.I0(counter[2]), .I1(1'b0), .CI(\add_22/n2 ), 
            .O(n6[2]), .CO(\add_22/n4 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i2 .I0_POLARITY = 1'b1;
    defparam \add_22/i2 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i1  (.I0(counter[1]), .I1(counter[0]), .CI(1'b0), 
            .O(n6[1]), .CO(\add_22/n2 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i1 .I0_POLARITY = 1'b1;
    defparam \add_22/i1 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i14  (.I0(counter[14]), .I1(1'b0), .CI(\add_22/n26 ), 
            .O(n6[14]), .CO(\add_22/n28 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i14 .I0_POLARITY = 1'b1;
    defparam \add_22/i14 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i17  (.I0(counter[17]), .I1(1'b0), .CI(\add_22/n32 ), 
            .O(n6[17]), .CO(\add_22/n34 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i17 .I0_POLARITY = 1'b1;
    defparam \add_22/i17 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i18  (.I0(counter[18]), .I1(1'b0), .CI(\add_22/n34 ), 
            .O(n6[18]), .CO(\add_22/n36 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i18 .I0_POLARITY = 1'b1;
    defparam \add_22/i18 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i19  (.I0(counter[19]), .I1(1'b0), .CI(\add_22/n36 ), 
            .O(n6[19]), .CO(\add_22/n38 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i19 .I0_POLARITY = 1'b1;
    defparam \add_22/i19 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i20  (.I0(counter[20]), .I1(1'b0), .CI(\add_22/n38 ), 
            .O(n6[20]), .CO(\add_22/n40 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i20 .I0_POLARITY = 1'b1;
    defparam \add_22/i20 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i21  (.I0(counter[21]), .I1(1'b0), .CI(\add_22/n40 ), 
            .O(n6[21]), .CO(\add_22/n42 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i21 .I0_POLARITY = 1'b1;
    defparam \add_22/i21 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i22  (.I0(SPI_MISO), .I1(1'b0), .CI(\add_22/n42 ), 
            .O(n6[22]), .CO(\add_22/n44 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i22 .I0_POLARITY = 1'b1;
    defparam \add_22/i22 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i23  (.I0(counter[23]), .I1(1'b0), .CI(\add_22/n44 ), 
            .O(n6[23]), .CO(\add_22/n46 )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i23 .I0_POLARITY = 1'b1;
    defparam \add_22/i23 .I1_POLARITY = 1'b1;
    EFX_ADD \add_22/i24  (.I0(LED[0]), .I1(1'b0), .CI(\add_22/n46 ), .O(n6[24])) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_ADD, I0_POLARITY=1'b1, I1_POLARITY=1'b1 */ ;   // C:\Users\Dimka\Documents\fixed_transform_codic\fpga\t20f169_spi_debug\top.v(36)
    defparam \add_22/i24 .I0_POLARITY = 1'b1;
    defparam \add_22/i24 .I1_POLARITY = 1'b1;
    EFX_GBUFCE CLKBUF__0 (.CE(1'b1), .I(pll_150Mhz), .O(\pll_150Mhz~O )) /* verific EFX_ATTRIBUTE_CELL_NAME=EFX_GBUFCE, CE_POLARITY=1'b1 */ ;
    defparam CLKBUF__0.CE_POLARITY = 1'b1;
    
endmodule

//
// Verific Verilog Description of module EFX_FF_20210986_0
// module not written out since it is a black box. 
//


//
// Verific Verilog Description of module EFX_FF_20210986_1
// module not written out since it is a black box. 
//


//
// Verific Verilog Description of module EFX_ADD_20210986_0
// module not written out since it is a black box. 
//


//
// Verific Verilog Description of module EFX_GBUFCE_20210986_0
// module not written out since it is a black box. 
//

