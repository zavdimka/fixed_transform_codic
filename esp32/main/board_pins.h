#pragma once

// ESP32-C5 schematic net names. GPIO13/GPIO14 belong to USB Serial/JTAG and
// must never be reconfigured by application code.
enum {
    BOARD_PIN_PAR_D0 = 0,
    BOARD_PIN_PAR_D1 = 1,
    BOARD_PIN_PAR_D2 = 2,
    BOARD_PIN_PAR_D3 = 3,
    BOARD_PIN_PAR_CLK = 4,
    BOARD_PIN_PAR_CS = 5,

    BOARD_PIN_SPI_CS = 6,
    BOARD_PIN_FPGA_CDONE = 7,
    BOARD_PIN_SPI_CLK = 8,
    BOARD_PIN_FPGA_CRESET = 9,
    BOARD_PIN_SPI_MOSI = 10,

    BOARD_PIN_FC_UART_TX = 11,
    BOARD_PIN_FC_UART_RX = 12,

    BOARD_PIN_TWI_SDA = 23,
    BOARD_PIN_TWI_SCK = 24,
    BOARD_PIN_CLK48 = 25,
    BOARD_PIN_SBUS = 26,
    BOARD_PIN_FPGA_INT = 27,
    BOARD_PIN_SPI_MISO = 28,
};
