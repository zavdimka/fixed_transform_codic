#include "board_io.h"

#include <stdint.h>

#include "board_pins.h"
#include "driver/gpio.h"

static esp_err_t configure_inputs(uint64_t mask)
{
    const gpio_config_t config = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&config);
}

static esp_err_t configure_outputs(uint64_t mask, uint32_t initial_high_mask)
{
    // Load output latches before enabling the drivers. In particular, this
    // prevents a short active-low pulse on SPI_CS or FPGA_CRESET at startup.
    for (unsigned pin = 0; pin < 32; ++pin) {
        if (mask & (UINT64_C(1) << pin)) {
            gpio_set_level(pin, (initial_high_mask >> pin) & 1U);
        }
    }
    const gpio_config_t config = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&config);
}

esp_err_t board_io_init(app_role_t role)
{
    const uint64_t par_data = BIT64(BOARD_PIN_PAR_D0) |
                              BIT64(BOARD_PIN_PAR_D1) |
                              BIT64(BOARD_PIN_PAR_D2) |
                              BIT64(BOARD_PIN_PAR_D3);
    const uint64_t common_inputs = BIT64(BOARD_PIN_PAR_CLK) |
                                   BIT64(BOARD_PIN_FPGA_CDONE) |
                                   BIT64(BOARD_PIN_SPI_MISO) |
                                   BIT64(BOARD_PIN_CLK48) |
                                   BIT64(BOARD_PIN_SBUS) |
                                   BIT64(BOARD_PIN_FPGA_INT) |
                                   BIT64(BOARD_PIN_FC_UART_RX);
    const uint64_t spi_outputs = BIT64(BOARD_PIN_SPI_CS) |
                                 BIT64(BOARD_PIN_FPGA_CRESET);

    esp_err_t err = configure_inputs(common_inputs);
    if (err != ESP_OK) {
        return err;
    }
    err = configure_outputs(spi_outputs,
                            BIT(BOARD_PIN_SPI_CS) | BIT(BOARD_PIN_FPGA_CRESET));
    if (err != ESP_OK) {
        return err;
    }

    if (role == APP_ROLE_RECEIVER) {
        return configure_outputs(par_data | BIT64(BOARD_PIN_PAR_CS), 0);
    }

    // Transmitter and service modes never drive the FPGA-to-ESP32 data bus.
    return configure_inputs(par_data | BIT64(BOARD_PIN_PAR_CS));
}
