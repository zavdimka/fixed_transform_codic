#include "fpga_loader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "board_pins.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_rom_sys.h"

#define FPGA_SPI_HOST SPI2_HOST
#define FPGA_SPI_CLOCK_HZ (8 * 1000 * 1000)
#define FPGA_CHUNK_SIZE 4096
#define FPGA_TRAILING_CLOCK_BYTES 16

static const char *TAG = "fpga_loader";

static bool has_binary_suffix(const char *path)
{
    const size_t length = strlen(path);
    return length >= 4 && strcmp(path + length - 4, ".bin") == 0;
}

static esp_err_t transmit(spi_device_handle_t device, const void *data,
                          size_t byte_count)
{
    spi_transaction_t transaction = {
        .length = byte_count * 8,
        .tx_buffer = data,
    };
    return spi_device_transmit(device, &transaction);
}

esp_err_t fpga_load_file(const char *path)
{
    if (path == NULL || !has_binary_suffix(path)) {
        ESP_LOGE(TAG, "expected an Efinity .hex.bin file");
        return ESP_ERR_INVALID_ARG;
    }

    struct stat status;
    if (stat(path, &status) != 0 || status.st_size <= 0) {
        ESP_LOGE(TAG, "FPGA image not found or empty: %s", path);
        return ESP_ERR_NOT_FOUND;
    }
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        ESP_LOGE(TAG, "cannot open FPGA image: %s", path);
        return ESP_FAIL;
    }

    uint8_t *buffer = heap_caps_malloc(FPGA_CHUNK_SIZE, MALLOC_CAP_DMA);
    if (buffer == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }

    const spi_bus_config_t bus_config = {
        .mosi_io_num = BOARD_PIN_SPI_MOSI,
        .miso_io_num = -1,
        .sclk_io_num = BOARD_PIN_SPI_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = FPGA_CHUNK_SIZE,
    };
    esp_err_t err = spi_bus_initialize(FPGA_SPI_HOST, &bus_config,
                                       SPI_DMA_CH_AUTO);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SPI bus init failed: %s", esp_err_to_name(err));
        free(buffer);
        fclose(file);
        return err;
    }

    const spi_device_interface_config_t device_config = {
        .clock_speed_hz = FPGA_SPI_CLOCK_HZ,
        .mode = 3,
        .spics_io_num = -1,
        .queue_size = 1,
    };
    spi_device_handle_t device = NULL;
    err = spi_bus_add_device(FPGA_SPI_HOST, &device_config, &device);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SPI device init failed: %s", esp_err_to_name(err));
        spi_bus_free(FPGA_SPI_HOST);
        free(buffer);
        fclose(file);
        return err;
    }

    ESP_LOGI(TAG, "loading %s (%lu bytes) at %u MHz", path,
             (unsigned long)status.st_size, FPGA_SPI_CLOCK_HZ / 1000000);

    // Efinix passive SPI x1: mode 3, active-low SS for the complete stream.
    gpio_set_level(BOARD_PIN_SPI_CS, 1);
    gpio_set_level(BOARD_PIN_FPGA_CRESET, 0);
    esp_rom_delay_us(10);
    gpio_set_level(BOARD_PIN_SPI_CS, 0);
    gpio_set_level(BOARD_PIN_FPGA_CRESET, 1);
    esp_rom_delay_us(1000);

    size_t total = 0;
    while (err == ESP_OK) {
        const size_t count = fread(buffer, 1, FPGA_CHUNK_SIZE, file);
        if (count == 0) {
            if (ferror(file)) {
                err = ESP_FAIL;
            }
            break;
        }
        err = transmit(device, buffer, count);
        total += count;
    }

    if (err == ESP_OK) {
        memset(buffer, 0, FPGA_TRAILING_CLOCK_BYTES);
        err = transmit(device, buffer, FPGA_TRAILING_CLOCK_BYTES);
    }
    esp_rom_delay_us(100);

    if (err == ESP_OK && gpio_get_level(BOARD_PIN_FPGA_CDONE) == 0) {
        ESP_LOGE(TAG, "CDONE stayed low after %u bytes", (unsigned)total);
        err = ESP_ERR_INVALID_RESPONSE;
    }
    gpio_set_level(BOARD_PIN_SPI_CS, 1);

    const esp_err_t remove_err = spi_bus_remove_device(device);
    const esp_err_t free_err = spi_bus_free(FPGA_SPI_HOST);
    free(buffer);
    fclose(file);

    if (err == ESP_OK && remove_err != ESP_OK) {
        err = remove_err;
    }
    if (err == ESP_OK && free_err != ESP_OK) {
        err = free_err;
    }
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "FPGA configured, CDONE=1");
    } else {
        ESP_LOGE(TAG, "FPGA configuration failed: %s", esp_err_to_name(err));
    }
    return err;
}
