
// Efinity Top-level template
// Version: 2026.1.132
// Date: 2026-08-16 21:36

// Copyright (C) 2013 - 2026 Efinix Inc. All rights reserved.

// This file may be used as a starting point for Efinity synthesis top-level target.
// The port list here matches what is expected by Efinity constraint files generated
// by the Efinity Interface Designer.

// To use this:
//     #1)  Save this file with a different name to a different directory, where source files are kept.
//              Example: you may wish to save as t20f169_spi_debug.v
//     #2)  Add the newly saved file into Efinity project as design file
//     #3)  Edit the top level entity in Efinity project to:  t20f169_spi_debug
//     #4)  Insert design content.


module t20f169_spi_debug
(
  (* syn_peri_port = 0 *) input CLK_48Mhz,
  (* syn_peri_port = 0 *) input SPI_CLK,
  (* syn_peri_port = 0 *) input SPI_CS,
  (* syn_peri_port = 0 *) input SPI_MOSI,
  (* syn_peri_port = 0 *) input pll_lock,
  (* syn_peri_port = 0 *) input [7:0] CSI_D,
  (* syn_peri_port = 0 *) input CSI_HSYNC,
  (* syn_peri_port = 0 *) input CSI_PCLK,
  (* syn_peri_port = 0 *) input CSI_VSYNC,
  (* syn_peri_port = 0 *) input pll_150Mhz,
  (* syn_peri_port = 0 *) input pll_24Mhz,
  (* syn_peri_port = 0 *) output [5:0] LED,
  (* syn_peri_port = 0 *) output SPI_MISO,
  (* syn_peri_port = 0 *) output pll_reset,
  (* syn_peri_port = 0 *) output CSI_MCLK,
  (* syn_peri_port = 0 *) output PAR_CLK,
  (* syn_peri_port = 0 *) output PAR_CS,
  (* syn_peri_port = 0 *) output [3:0] PAR_D
);


endmodule

