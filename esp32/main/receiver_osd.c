#include "receiver_osd.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "osd_font7x10.h"
#include "radio_link.h"

#define OSD_SPI_HOST SPI2_HOST
#define OSD_SPI_CLOCK_HZ (5 * 1000 * 1000)
#define OSD_LOGICAL_WIDTH 640
#define OSD_CELL_WIDTH 8
#define OSD_CELL_HEIGHT 12
#define OSD_WORD_BITS 40
#define OSD_WORDS_PER_SCANLINE (OSD_LOGICAL_WIDTH / OSD_WORD_BITS)

#define CMD_OSD_CONFIG 0x01
#define CMD_OSD_SET_ADDRESS 0x10
#define CMD_OSD_WRITE 0x11
#define CMD_OSD_CLEAR 0x12
#define CMD_OSD_ATTRIBUTE_SET_ADDRESS 0x13
#define CMD_OSD_ATTRIBUTE_WRITE 0x14
#define CMD_READ_STATUS 0x80
#define CMD_READ_LINK_STATUS 0x90
#define CMD_READ_PARSER_COUNTS 0x92
#define CMD_READ_PARSER_ERRORS 0x93
#define CMD_READ_DECODER_STATUS 0x94

#define OSD_PROTOCOL_SIGNATURE 0xc5
#define OSD_PROTOCOL_VERSION 0x14

// Bright programmable foreground, opaque black background.
#define STATS_ATTRIBUTE 0x10f

typedef struct {
    uint32_t hdmi_frames;
    uint16_t fifo_level;
    uint32_t link_bytes;
    uint32_t parser_accepted;
    uint32_t parser_rejected;
    uint32_t crc_errors;
    uint32_t length_errors;
    uint32_t framing_errors;
    uint32_t decoded;
    uint32_t decoder_rejected;
    uint32_t syntax_errors;
} fpga_stats_t;

static const char *TAG = "receiver_osd";
static spi_device_handle_t s_device;
static SemaphoreHandle_t s_mutex;
static TaskHandle_t s_task;
static bool s_running;
static uint8_t s_channel;
static uint8_t s_bandwidth_mhz;

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
    if (size > 20) {
        return ESP_ERR_INVALID_SIZE;
    }
    uint8_t tx[21] = {command};
    uint8_t rx[21] = {0};
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

static esp_err_t set_bitmap_address(uint16_t address)
{
    const uint8_t command[] = {
        CMD_OSD_SET_ADDRESS, (uint8_t)address, (uint8_t)(address >> 8),
    };
    return spi_write(command, sizeof(command));
}

static esp_err_t write_scanline(uint16_t address,
                                const uint64_t words[OSD_WORDS_PER_SCANLINE])
{
    esp_err_t err = set_bitmap_address(address);
    if (err != ESP_OK) {
        return err;
    }

    uint8_t command[1 + OSD_WORDS_PER_SCANLINE * 5] = {CMD_OSD_WRITE};
    for (unsigned word = 0; word < OSD_WORDS_PER_SCANLINE; ++word) {
        for (unsigned byte = 0; byte < 5; ++byte) {
            command[1 + word * 5 + byte] = words[word] >> (byte * 8);
        }
    }
    return spi_write(command, sizeof(command));
}

static esp_err_t write_row_attribute(uint8_t row, uint16_t attribute)
{
    const uint16_t address = (uint16_t)row * RECEIVER_OSD_COLUMNS;
    const uint8_t set_address[] = {
        CMD_OSD_ATTRIBUTE_SET_ADDRESS,
        (uint8_t)address,
        (uint8_t)(address >> 8),
    };
    esp_err_t err = spi_write(set_address, sizeof(set_address));
    if (err != ESP_OK) {
        return err;
    }

    uint8_t command[1 + RECEIVER_OSD_COLUMNS * 2] = {CMD_OSD_ATTRIBUTE_WRITE};
    for (unsigned column = 0; column < RECEIVER_OSD_COLUMNS; ++column) {
        command[1 + column * 2] = attribute;
        command[2 + column * 2] = (attribute >> 8) & 0x03;
    }
    return spi_write(command, sizeof(command));
}

static esp_err_t write_line_locked(uint8_t row, const char *text,
                                   uint16_t attribute)
{
    if (row >= RECEIVER_OSD_ROWS || text == NULL || attribute > 0x03ff) {
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t err = write_row_attribute(row, attribute);
    for (unsigned scanline = 0; scanline < OSD_CELL_HEIGHT && err == ESP_OK;
         ++scanline) {
        uint64_t words[OSD_WORDS_PER_SCANLINE] = {0};
        // A 7x10 glyph occupies rows 1..10 of the 8x12 attribute cell,
        // leaving one blank scanline above/below and column 7 as spacing.
        const int glyph_y = (int)scanline - 1;
        if (glyph_y >= 0 && glyph_y < OSD_FONT_HEIGHT) {
            for (unsigned column = 0; column < RECEIVER_OSD_COLUMNS; ++column) {
                const char character = text[column] == '\0' ? ' ' : text[column];
                const uint8_t glyph = osd_font7x10_row(character, glyph_y);
                for (unsigned glyph_x = 0; glyph_x < OSD_FONT_WIDTH; ++glyph_x) {
                    if ((glyph >> glyph_x) & 1U) {
                        const unsigned x = column * OSD_CELL_WIDTH + glyph_x;
                        words[x / OSD_WORD_BITS] |= UINT64_C(1)
                                                     << (x % OSD_WORD_BITS);
                    }
                }
                if (text[column] == '\0') {
                    break;
                }
            }
        }
        const uint16_t bitmap_address =
            ((uint16_t)row * OSD_CELL_HEIGHT + scanline) *
            OSD_WORDS_PER_SCANLINE;
        err = write_scanline(bitmap_address, words);
    }
    return err;
}

esp_err_t receiver_osd_write_line(uint8_t row, const char *text,
                                  uint16_t attribute)
{
    if (!s_running || s_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    const esp_err_t err = write_line_locked(row, text, attribute);
    xSemaphoreGive(s_mutex);
    return err;
}

static esp_err_t read_fpga_stats(fpga_stats_t *stats)
{
    uint8_t status[11];
    uint8_t link[12];
    uint8_t parser[8];
    uint8_t errors[12];
    uint8_t decoder[16];

    esp_err_t err = spi_read_command(CMD_READ_STATUS, status, sizeof(status));
    if (err != ESP_OK || status[0] != OSD_PROTOCOL_SIGNATURE ||
        status[1] != OSD_PROTOCOL_VERSION) {
        return err == ESP_OK ? ESP_ERR_INVALID_RESPONSE : err;
    }
    if ((err = spi_read_command(CMD_READ_LINK_STATUS, link, sizeof(link))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_PARSER_COUNTS, parser, sizeof(parser))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_PARSER_ERRORS, errors, sizeof(errors))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_DECODER_STATUS, decoder, sizeof(decoder))) != ESP_OK) {
        return err;
    }

    *stats = (fpga_stats_t) {
        .hdmi_frames = read_le32(status + 3),
        .fifo_level = read_le16(link),
        .link_bytes = read_le32(link + 3),
        .parser_accepted = read_le32(parser),
        .parser_rejected = read_le32(parser + 4),
        .crc_errors = read_le32(errors),
        .length_errors = read_le32(errors + 4),
        .framing_errors = read_le32(errors + 8),
        .decoded = read_le32(decoder + 3),
        .decoder_rejected = read_le32(decoder + 7),
        .syntax_errors = read_le32(decoder + 11),
    };
    return ESP_OK;
}

static void statistics_task(void *argument)
{
    (void)argument;
    uint32_t previous_packets = 0;
    TickType_t wake_time = xTaskGetTickCount();

    for (;;) {
        radio_link_stats_t radio;
        radio_link_get_stats(&radio);
        const uint32_t packets_per_second = radio.rx_packets - previous_packets;
        previous_packets = radio.rx_packets;
        const uint64_t received_and_lost =
            (uint64_t)radio.rx_packets + radio.rx_lost;
        const unsigned loss_percent = received_and_lost == 0
                                          ? 0
                                          : (unsigned)((uint64_t)radio.rx_lost *
                                                       100 / received_and_lost);

        fpga_stats_t fpga = {0};
        esp_err_t fpga_err;
        if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            fpga_err = read_fpga_stats(&fpga);
            xSemaphoreGive(s_mutex);
        } else {
            fpga_err = ESP_ERR_TIMEOUT;
        }

        char line[RECEIVER_OSD_COLUMNS + 1];
        snprintf(line, sizeof(line),
                 "FPV RX  CH %3u  BW %2uM  RSSI %4d DBM  HDMI %10" PRIu32,
                 s_channel, s_bandwidth_mhz, radio.rssi_dbm, fpga.hdmi_frames);
        (void)receiver_osd_write_line(0, line, STATS_ATTRIBUTE);
        snprintf(line, sizeof(line),
                 "WIFI PKT %10" PRIu32 "  PPS %5" PRIu32
                 "  LOST %8" PRIu32 "  %3u%%",
                 radio.rx_packets, packets_per_second, radio.rx_lost,
                 loss_percent);
        (void)receiver_osd_write_line(1, line, STATS_ATTRIBUTE);

        if (fpga_err == ESP_OK) {
            snprintf(line, sizeof(line),
                     "FPGA FIFO %4u  BYTES %10" PRIu32
                     "  RECORDS %8" PRIu32 "  BAD %6" PRIu32,
                     fpga.fifo_level, fpga.link_bytes, fpga.parser_accepted,
                     fpga.parser_rejected);
            (void)receiver_osd_write_line(2, line, STATS_ATTRIBUTE);
            snprintf(line, sizeof(line),
                     "DEC OK %8" PRIu32 "  BAD %6" PRIu32
                     "  CRC %6" PRIu32 "  LEN %6" PRIu32 "  SYN %6" PRIu32,
                     fpga.decoded, fpga.decoder_rejected, fpga.crc_errors,
                     fpga.length_errors, fpga.syntax_errors);
        } else {
            snprintf(line, sizeof(line), "FPGA SPI ERROR: %s",
                     esp_err_to_name(fpga_err));
            (void)receiver_osd_write_line(2, line, STATS_ATTRIBUTE);
        }
        (void)receiver_osd_write_line(3, line, STATS_ATTRIBUTE);

        xTaskDelayUntil(&wake_time, pdMS_TO_TICKS(1000));
    }
}

bool receiver_osd_is_running(void)
{
    return s_running;
}

esp_err_t receiver_osd_start(const app_config_t *config)
{
    if (config == NULL || config->role != APP_ROLE_RECEIVER || s_running) {
        return ESP_ERR_INVALID_STATE;
    }

    const spi_bus_config_t bus_config = {
        .mosi_io_num = BOARD_PIN_SPI_MOSI,
        .miso_io_num = BOARD_PIN_SPI_MISO,
        .sclk_io_num = BOARD_PIN_SPI_CLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 256,
    };
    esp_err_t err = spi_bus_initialize(OSD_SPI_HOST, &bus_config,
                                       SPI_DMA_CH_AUTO);
    if (err != ESP_OK) {
        return err;
    }

    const spi_device_interface_config_t device_config = {
        .clock_speed_hz = OSD_SPI_CLOCK_HZ,
        .mode = 0,
        .spics_io_num = BOARD_PIN_SPI_CS,
        .queue_size = 1,
    };
    err = spi_bus_add_device(OSD_SPI_HOST, &device_config, &s_device);
    if (err != ESP_OK) {
        spi_bus_free(OSD_SPI_HOST);
        return err;
    }

    s_mutex = xSemaphoreCreateMutex();
    if (s_mutex == NULL) {
        spi_bus_remove_device(s_device);
        spi_bus_free(OSD_SPI_HOST);
        s_device = NULL;
        return ESP_ERR_NO_MEM;
    }

    uint8_t status[11];
    err = spi_read_command(CMD_READ_STATUS, status, sizeof(status));
    if (err == ESP_OK && (status[0] != OSD_PROTOCOL_SIGNATURE ||
                          status[1] != OSD_PROTOCOL_VERSION)) {
        err = ESP_ERR_INVALID_RESPONSE;
    }
    if (err == ESP_OK) {
        const uint8_t clear[] = {CMD_OSD_CLEAR};
        err = spi_write(clear, sizeof(clear));
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    if (err == ESP_OK) {
        const uint8_t configure[] = {CMD_OSD_CONFIG, 1, 255, 255, 255};
        err = spi_write(configure, sizeof(configure));
    }
    if (err != ESP_OK) {
        vSemaphoreDelete(s_mutex);
        s_mutex = NULL;
        spi_bus_remove_device(s_device);
        spi_bus_free(OSD_SPI_HOST);
        s_device = NULL;
        return err;
    }

    s_channel = config->channel;
    s_bandwidth_mhz = config->bandwidth_mhz;
    s_running = true;
    if (xTaskCreate(statistics_task, "rx_osd_stats", 4096, NULL, 5, &s_task) !=
        pdPASS) {
        s_running = false;
        vSemaphoreDelete(s_mutex);
        s_mutex = NULL;
        spi_bus_remove_device(s_device);
        spi_bus_free(OSD_SPI_HOST);
        s_device = NULL;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "OSD statistics active, rows 0..%u", RECEIVER_OSD_STATS_ROWS - 1);
    return ESP_OK;
}
