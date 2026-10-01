#include "transmitter_diag.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TX_DIAG_SPI_HOST SPI2_HOST
#define TX_DIAG_SPI_CLOCK_HZ (8 * 1000 * 1000)

#define CMD_SET_QUALITY 0x03
#define CMD_ARM_CAPTURE 0x20
#define CMD_SET_SNAPSHOT_ADDRESS 0x22
#define CMD_READ_STATUS 0x80
#define CMD_READ_CAPTURE 0x81
#define CMD_READ_SNAPSHOT_WORD 0x82

#define TX_PROTOCOL_SIGNATURE 0xc5
#define TX_PROTOCOL_VERSION 0x02

typedef struct {
    uint8_t flags;
    uint8_t state;
    uint8_t quality;
    uint16_t gap_cycles;
    uint16_t packet_bytes;
    uint32_t packet_count;
    uint16_t camera_frame_id;
    uint16_t dropped_stripes;
    uint8_t codec_ctu;
    uint8_t codec_state;
    uint8_t completed_ctus;
    uint8_t handshake;
} tx_status_t;

static const char *TAG = "transmitter_diag";
static spi_device_handle_t s_device;

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static uint32_t read_le32(const uint8_t *data)
{
    return (uint32_t)data[0] | ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

static esp_err_t spi_write(const uint8_t *data, size_t size)
{
    spi_transaction_t transaction = {
        .length = size * 8,
        .tx_buffer = data,
    };
    return spi_device_transmit(s_device, &transaction);
}

static esp_err_t spi_read_command(uint8_t command, uint8_t *data, size_t size)
{
    if (size > 24) {
        return ESP_ERR_INVALID_SIZE;
    }
    uint8_t tx[25] = {command};
    uint8_t rx[25] = {0};
    spi_transaction_t transaction = {
        .length = (size + 1) * 8,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    const esp_err_t err = spi_device_transmit(s_device, &transaction);
    if (err == ESP_OK) {
        memcpy(data, rx + 1, size);
    }
    return err;
}

static esp_err_t read_status(tx_status_t *status)
{
    uint8_t raw[20] = {0};
    esp_err_t err = spi_read_command(CMD_READ_STATUS, raw, sizeof(raw));
    if (err != ESP_OK) {
        return err;
    }
    if (raw[0] != TX_PROTOCOL_SIGNATURE || raw[1] != TX_PROTOCOL_VERSION) {
        ESP_LOGE(TAG, "FPGA status mismatch: signature=%02x version=%02x",
                 raw[0], raw[1]);
        return ESP_ERR_INVALID_RESPONSE;
    }
    *status = (tx_status_t) {
        .flags = raw[2],
        .state = raw[3],
        .quality = (raw[3] & (1U << 5)) ? 24 : 20,
        .gap_cycles = read_le16(raw + 4),
        .packet_bytes = read_le16(raw + 6),
        .packet_count = read_le32(raw + 8),
        .camera_frame_id = read_le16(raw + 12),
        .dropped_stripes = read_le16(raw + 14),
        .codec_ctu = raw[16],
        .codec_state = raw[17],
        .completed_ctus = raw[18],
        .handshake = raw[19],
    };
    return ESP_OK;
}

esp_err_t transmitter_diag_start(void)
{
    if (s_device != NULL) {
        return ESP_OK;
    }
    const spi_bus_config_t bus_config = {
        .mosi_io_num = BOARD_PIN_SPI_MOSI,
        .miso_io_num = BOARD_PIN_SPI_MISO,
        .sclk_io_num = BOARD_PIN_SPI_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 64,
    };
    esp_err_t err = spi_bus_initialize(TX_DIAG_SPI_HOST, &bus_config,
                                       SPI_DMA_CH_AUTO);
    if (err != ESP_OK) {
        return err;
    }
    const spi_device_interface_config_t device_config = {
        .clock_speed_hz = TX_DIAG_SPI_CLOCK_HZ,
        .mode = 0,
        .spics_io_num = BOARD_PIN_SPI_CS,
        .queue_size = 1,
    };
    err = spi_bus_add_device(TX_DIAG_SPI_HOST, &device_config, &s_device);
    if (err != ESP_OK) {
        spi_bus_free(TX_DIAG_SPI_HOST);
    }
    return err;
}

esp_err_t transmitter_diag_stop(void)
{
    if (s_device == NULL) {
        return ESP_OK;
    }
    const esp_err_t remove_err = spi_bus_remove_device(s_device);
    if (remove_err != ESP_OK) {
        return remove_err;
    }
    s_device = NULL;
    return spi_bus_free(TX_DIAG_SPI_HOST);
}

esp_err_t transmitter_diag_print_status(void)
{
    esp_err_t err = transmitter_diag_start();
    tx_status_t status = {0};
    if (err == ESP_OK) {
        err = read_status(&status);
    }
    if (err == ESP_OK) {
        const int64_t now_us = esp_timer_get_time();
        printf("tx fpga t_us=%" PRId64 " flags=0x%02x state=0x%02x quality=%u gap=%u "
               "packet_bytes=%u packet_count=%" PRIu32 " "
               "camera_frame=%u dropped_stripes=%u "
               "codec_ctu=%u codec_state=%u completed=%u hs=0x%02x\n",
               now_us, status.flags, status.state, status.quality,
               status.gap_cycles,
               status.packet_bytes, status.packet_count,
               status.camera_frame_id, status.dropped_stripes,
               status.codec_ctu, status.codec_state,
               status.completed_ctus, status.handshake);
    }
    return err;
}
esp_err_t transmitter_diag_set_gap(uint16_t cycles)
{
    if (cycles == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t err = transmitter_diag_start();
    if (err != ESP_OK) {
        return err;
    }
    const uint8_t command[] = {
        0x01, (uint8_t)cycles, (uint8_t)(cycles >> 8),
    };
    return spi_write(command, sizeof(command));
}
esp_err_t transmitter_diag_set_quality(uint8_t quality)
{
    if (quality != 20 && quality != 24) {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t err = transmitter_diag_start();
    if (err != ESP_OK) {
        return err;
    }
    const uint8_t command[] = {CMD_SET_QUALITY, quality == 24};
    return spi_write(command, sizeof(command));
}

esp_err_t transmitter_diag_arm_capture(void)
{
    esp_err_t err = transmitter_diag_start();
    if (err != ESP_OK) {
        return err;
    }
    const uint8_t arm = CMD_ARM_CAPTURE;
    return spi_write(&arm, sizeof(arm));
}

esp_err_t transmitter_diag_capture(void)
{
    esp_err_t err = transmitter_diag_arm_capture();
    if (err != ESP_OK) {
        return err;
    }

    tx_status_t status = {0};
    bool finished = false;
    for (unsigned attempt = 0; attempt < 300; ++attempt) {
        vTaskDelay(pdMS_TO_TICKS(10));
        err = read_status(&status);
        if (err != ESP_OK) {
            return err;
        }
        if (status.flags & (1U << 2)) {
            finished = true;
            break;
        }
    }
    if (!finished) {
        printf("camera capture timeout: flags=0x%02x\n", status.flags);
        return ESP_ERR_TIMEOUT;
    }

    uint8_t capture[7] = {0};
    err = spi_read_command(CMD_READ_CAPTURE, capture, sizeof(capture));
    if (err != ESP_OK) {
        return err;
    }
    printf("camera capture raw=");
    for (unsigned index = 0; index < sizeof(capture); ++index) {
        printf("%02x", capture[index]);
    }
    putchar('\n');
    const uint16_t lines = read_le16(capture);
    const uint16_t line_bytes = read_le16(capture + 2);
    const uint16_t words = read_le16(capture + 4) & 0x7fff;

    const uint8_t set_address[] = {CMD_SET_SNAPSHOT_ADDRESS, 0, 0};
    err = spi_write(set_address, sizeof(set_address));
    vTaskDelay(pdMS_TO_TICKS(1));
    uint32_t checksum = 0;
    unsigned valid_words = 0;
    printf("camera samples=");
    for (unsigned index = 0; index < 64 && err == ESP_OK; ++index) {
        uint8_t word[6] = {0};
        err = spi_read_command(CMD_READ_SNAPSHOT_WORD, word, sizeof(word));
        if (index < 4) {
            printf("[%02x%02x%02x%02x%02x:%02x]",
                   word[0], word[1], word[2], word[3], word[4], word[5]);
        }
        if (err == ESP_OK && (word[5] & 1U)) {
            ++valid_words;
            for (unsigned byte = 0; byte < 5; ++byte) {
                checksum = (checksum << 5) ^ (checksum >> 27) ^ word[byte];
                printf("%02x", word[byte]);
            }
        }
    }
    putchar('\n');
    if (err == ESP_OK) {
        printf("camera capture lines=%u line_bytes=%u words=%u "
               "capture_error=%u sample_words=%u sample_checksum=%08" PRIx32
               "\n",
               lines, line_bytes, words, (status.flags >> 3) & 1U,
               valid_words, checksum);
    }
    return err;
}
