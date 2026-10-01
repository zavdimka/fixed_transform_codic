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
#define OSD_SPI_CLOCK_HZ (8 * 1000 * 1000)
#define OSD_LOGICAL_WIDTH 640
#define OSD_CELL_WIDTH 8
#define OSD_CELL_HEIGHT 12
#define OSD_WORD_BITS 40
#define OSD_WORDS_PER_SCANLINE (OSD_LOGICAL_WIDTH / OSD_WORD_BITS)

#define CMD_OSD_CONFIG 0x01
#define CMD_TEST_PATTERN 0x03
#define CMD_OSD_SET_ADDRESS 0x10
#define CMD_OSD_WRITE 0x11
#define CMD_OSD_CLEAR 0x12
#define CMD_OSD_ATTRIBUTE_SET_ADDRESS 0x13
#define CMD_OSD_ATTRIBUTE_WRITE 0x14
#define CMD_READ_STATUS 0x80
#define CMD_READ_LINK_STATUS 0x90
#define CMD_READ_PARSER_STATUS 0x91
#define CMD_READ_PARSER_COUNTS 0x92
#define CMD_READ_PARSER_ERRORS 0x93
#define CMD_READ_DECODER_STATUS 0x94
#define CMD_READ_ENHANCEMENT_STATUS 0x95

#define OSD_PROTOCOL_SIGNATURE 0xc5
#define OSD_PROTOCOL_VERSION 0x14

#define OSD_TRANSPARENT(color) \
    RECEIVER_OSD_ATTRIBUTE((color), RECEIVER_OSD_BLACK, false)
#define STATS_TITLE_ATTRIBUTE OSD_TRANSPARENT(RECEIVER_OSD_BRIGHT_MAGENTA)
#define STATS_LABEL_ATTRIBUTE OSD_TRANSPARENT(RECEIVER_OSD_BRIGHT_CYAN)
#define STATS_VALUE_ATTRIBUTE OSD_TRANSPARENT(RECEIVER_OSD_YELLOW)
#define STATS_GOOD_ATTRIBUTE OSD_TRANSPARENT(RECEIVER_OSD_BRIGHT_GREEN)
#define STATS_ERROR_ATTRIBUTE OSD_TRANSPARENT(RECEIVER_OSD_BRIGHT_RED)

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
    uint32_t displayed_stripes;
    uint32_t missing_stripes;
    uint8_t decoder_flags;
    uint8_t enhancement_flags;
    uint16_t enhancement_coefficient_xor;
    uint32_t enhancement_completed;
    uint32_t enhancement_rejected;
    uint32_t enhancement_syntax_errors;
    uint8_t parser_flags;
    uint8_t parser_record_type;
    uint8_t parser_stripe_id;
    uint16_t parser_payload_length;
    uint8_t parser_payload_xor;
    uint16_t parser_record_sequence;
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

static esp_err_t write_row_attributes(
    uint8_t row, const uint16_t attributes[RECEIVER_OSD_COLUMNS])
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
        command[1 + column * 2] = attributes[column];
        command[2 + column * 2] = (attributes[column] >> 8) & 0x03;
    }
    return spi_write(command, sizeof(command));
}

static esp_err_t write_row_attribute(uint8_t row, uint16_t attribute)
{
    uint16_t attributes[RECEIVER_OSD_COLUMNS];
    for (unsigned column = 0; column < RECEIVER_OSD_COLUMNS; ++column) {
        attributes[column] = attribute;
    }
    return write_row_attributes(row, attributes);
}

static esp_err_t write_bitmap_line(uint8_t row, const char *text)
{
    esp_err_t err = ESP_OK;
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

static esp_err_t write_line_locked(uint8_t row, const char *text,
                                   uint16_t attribute)
{
    if (row >= RECEIVER_OSD_ROWS || text == NULL || attribute > 0x03ff) {
        return ESP_ERR_INVALID_ARG;
    }
    const esp_err_t err = write_row_attribute(row, attribute);
    return err == ESP_OK ? write_bitmap_line(row, text) : err;
}

static esp_err_t write_spans_locked(uint8_t row,
                                    const receiver_osd_span_t *spans,
                                    size_t span_count)
{
    if (row >= RECEIVER_OSD_ROWS || (spans == NULL && span_count != 0)) {
        return ESP_ERR_INVALID_ARG;
    }

    char text[RECEIVER_OSD_COLUMNS + 1];
    uint16_t attributes[RECEIVER_OSD_COLUMNS];
    memset(text, ' ', RECEIVER_OSD_COLUMNS);
    text[RECEIVER_OSD_COLUMNS] = '\0';
    for (unsigned column = 0; column < RECEIVER_OSD_COLUMNS; ++column) {
        attributes[column] = OSD_TRANSPARENT(RECEIVER_OSD_PROGRAMMABLE);
    }

    size_t column = 0;
    for (size_t span = 0; span < span_count; ++span) {
        if (spans[span].text == NULL || spans[span].attribute > 0x03ff) {
            return ESP_ERR_INVALID_ARG;
        }
        for (const char *source = spans[span].text;
             *source != '\0' && column < RECEIVER_OSD_COLUMNS;
             ++source, ++column) {
            text[column] = *source;
            attributes[column] = spans[span].attribute;
        }
    }

    const esp_err_t err = write_row_attributes(row, attributes);
    return err == ESP_OK ? write_bitmap_line(row, text) : err;
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

esp_err_t receiver_osd_write_spans(uint8_t row,
                                   const receiver_osd_span_t *spans,
                                   size_t span_count)
{
    if (!s_running || s_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    const esp_err_t err = write_spans_locked(row, spans, span_count);
    xSemaphoreGive(s_mutex);
    return err;
}

static esp_err_t read_fpga_stats(fpga_stats_t *stats)
{
    uint8_t status[11];
    uint8_t link[12];
    uint8_t parser_status[8];
    uint8_t parser[8];
    uint8_t errors[12];
    uint8_t decoder[24];
    uint8_t enhancement[16];

    esp_err_t err = spi_read_command(CMD_READ_STATUS, status, sizeof(status));
    if (err != ESP_OK || status[0] != OSD_PROTOCOL_SIGNATURE ||
        status[1] != OSD_PROTOCOL_VERSION) {
        return err == ESP_OK ? ESP_ERR_INVALID_RESPONSE : err;
    }
    if ((err = spi_read_command(CMD_READ_LINK_STATUS, link, sizeof(link))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_PARSER_STATUS, parser_status, sizeof(parser_status))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_PARSER_COUNTS, parser, sizeof(parser))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_PARSER_ERRORS, errors, sizeof(errors))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_DECODER_STATUS, decoder, sizeof(decoder))) != ESP_OK ||
        (err = spi_read_command(CMD_READ_ENHANCEMENT_STATUS, enhancement, sizeof(enhancement))) != ESP_OK) {
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
        .displayed_stripes = read_le32(decoder + 15),
        .missing_stripes = read_le32(decoder + 19),
        .decoder_flags = decoder[0],
        .enhancement_flags = enhancement[0],
        .enhancement_coefficient_xor = read_le16(enhancement + 1),
        .enhancement_completed = read_le32(enhancement + 3),
        .enhancement_rejected = read_le32(enhancement + 7),
        .enhancement_syntax_errors = read_le32(enhancement + 11),
        .parser_flags = parser_status[0],
        .parser_record_type = parser_status[1],
        .parser_stripe_id = parser_status[2],
        .parser_payload_length = read_le16(parser_status + 3),
        .parser_payload_xor = parser_status[5],
        .parser_record_sequence = read_le16(parser_status + 6),
    };
    return ESP_OK;
}

esp_err_t receiver_osd_print_fpga_stats(void)
{
    if (!s_running || s_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    fpga_stats_t stats = {0};
    const esp_err_t err = read_fpga_stats(&stats);
    xSemaphoreGive(s_mutex);
    if (err == ESP_OK) {
        printf("fpga hdmi=%" PRIu32 " fifo=%u bytes=%" PRIu32
               " records=%" PRIu32 " rejected=%" PRIu32
               " crc=%" PRIu32 " length=%" PRIu32 " framing=%" PRIu32
               " decoded=%" PRIu32 " decoder_rejected=%" PRIu32
               " syntax=%" PRIu32 " displayed=%" PRIu32 " missing=%" PRIu32 "\n",
               stats.hdmi_frames, stats.fifo_level, stats.link_bytes,
               stats.parser_accepted, stats.parser_rejected, stats.crc_errors,
               stats.length_errors, stats.framing_errors, stats.decoded,
               stats.decoder_rejected, stats.syntax_errors,
               stats.displayed_stripes, stats.missing_stripes);
        printf("fpga decoder_flags=0x%02x enhancement_flags=0x%02x "
               "enhancement_xor=0x%04x completed=%" PRIu32
               " rejected=%" PRIu32 " syntax=%" PRIu32 "\n",
               stats.decoder_flags, stats.enhancement_flags,
               stats.enhancement_coefficient_xor,
               stats.enhancement_completed, stats.enhancement_rejected,
               stats.enhancement_syntax_errors);
        printf("fpga parser_flags=0x%02x type=0x%02x stripe=%u "
               "length=%u xor=0x%02x sequence=%u\n",
               stats.parser_flags, stats.parser_record_type,
               stats.parser_stripe_id, stats.parser_payload_length,
               stats.parser_payload_xor, stats.parser_record_sequence);
    }
    return err;
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

        char channel_text[4], bandwidth_text[5], rssi_text[7], hdmi_text[12];
        snprintf(channel_text, sizeof(channel_text), "%3u", s_channel);
        snprintf(bandwidth_text, sizeof(bandwidth_text), "%2uM",
                 s_bandwidth_mhz);
        snprintf(rssi_text, sizeof(rssi_text), "%4d", radio.rssi_dbm);
        snprintf(hdmi_text, sizeof(hdmi_text), "%10" PRIu32,
                 fpga.hdmi_frames);
        const receiver_osd_span_t row0[] = {
            {"FPV RX", STATS_TITLE_ATTRIBUTE},
            {"  CH ", STATS_LABEL_ATTRIBUTE},
            {channel_text, STATS_VALUE_ATTRIBUTE},
            {"  BW ", STATS_LABEL_ATTRIBUTE},
            {bandwidth_text, STATS_VALUE_ATTRIBUTE},
            {"  RSSI ", STATS_LABEL_ATTRIBUTE},
            {rssi_text, STATS_VALUE_ATTRIBUTE},
            {" DBM  HDMI ", STATS_LABEL_ATTRIBUTE},
            {hdmi_text, STATS_GOOD_ATTRIBUTE},
        };
        (void)receiver_osd_write_spans(
            0, row0, sizeof(row0) / sizeof(row0[0]));

        char packets_text[12], pps_text[7], lost_text[10], loss_text[6];
        snprintf(packets_text, sizeof(packets_text), "%10" PRIu32,
                 radio.rx_packets);
        snprintf(pps_text, sizeof(pps_text), "%5" PRIu32,
                 packets_per_second);
        snprintf(lost_text, sizeof(lost_text), "%8" PRIu32, radio.rx_lost);
        snprintf(loss_text, sizeof(loss_text), "%3u%%", loss_percent);
        const uint16_t loss_attribute = radio.rx_lost == 0
                                            ? STATS_GOOD_ATTRIBUTE
                                            : STATS_ERROR_ATTRIBUTE;
        const receiver_osd_span_t row1[] = {
            {"WIFI", STATS_TITLE_ATTRIBUTE},
            {" PKT ", STATS_LABEL_ATTRIBUTE},
            {packets_text, STATS_VALUE_ATTRIBUTE},
            {"  PPS ", STATS_LABEL_ATTRIBUTE},
            {pps_text, STATS_GOOD_ATTRIBUTE},
            {"  LOST ", STATS_LABEL_ATTRIBUTE},
            {lost_text, loss_attribute},
            {"  ", STATS_LABEL_ATTRIBUTE},
            {loss_text, loss_attribute},
        };
        (void)receiver_osd_write_spans(
            1, row1, sizeof(row1) / sizeof(row1[0]));

        if (fpga_err == ESP_OK) {
            char fifo_text[6], bytes_text[12], records_text[10], bad1_text[8];
            snprintf(fifo_text, sizeof(fifo_text), "%4u", fpga.fifo_level);
            snprintf(bytes_text, sizeof(bytes_text), "%10" PRIu32,
                     fpga.link_bytes);
            snprintf(records_text, sizeof(records_text), "%8" PRIu32,
                     fpga.parser_accepted);
            snprintf(bad1_text, sizeof(bad1_text), "%6" PRIu32,
                     fpga.parser_rejected);
            const receiver_osd_span_t row2[] = {
                {"FPGA", STATS_TITLE_ATTRIBUTE},
                {" FIFO ", STATS_LABEL_ATTRIBUTE},
                {fifo_text, STATS_VALUE_ATTRIBUTE},
                {"  BYTES ", STATS_LABEL_ATTRIBUTE},
                {bytes_text, STATS_VALUE_ATTRIBUTE},
                {"  RECORDS ", STATS_LABEL_ATTRIBUTE},
                {records_text, STATS_GOOD_ATTRIBUTE},
                {"  BAD ", STATS_LABEL_ATTRIBUTE},
                {bad1_text, fpga.parser_rejected == 0
                                ? STATS_GOOD_ATTRIBUTE
                                : STATS_ERROR_ATTRIBUTE},
            };
            (void)receiver_osd_write_spans(
                2, row2, sizeof(row2) / sizeof(row2[0]));

            char decoded_text[10], displayed_text[10], missing_text[10];
            char enhancement_text[10], bad2_text[8];
            const uint32_t decoder_bad = fpga.decoder_rejected +
                                         fpga.enhancement_rejected;
            snprintf(decoded_text, sizeof(decoded_text), "%8" PRIu32,
                     fpga.decoded);
            snprintf(displayed_text, sizeof(displayed_text), "%8" PRIu32,
                     fpga.displayed_stripes);
            snprintf(missing_text, sizeof(missing_text), "%8" PRIu32,
                     fpga.missing_stripes);
            snprintf(enhancement_text, sizeof(enhancement_text), "%8" PRIu32,
                     fpga.enhancement_completed);
            snprintf(bad2_text, sizeof(bad2_text), "%6" PRIu32, decoder_bad);
            const receiver_osd_span_t row3[] = {
                {"DEC", STATS_TITLE_ATTRIBUTE}, {" ", STATS_LABEL_ATTRIBUTE},
                {decoded_text, STATS_VALUE_ATTRIBUTE},
                {"  DISP ", STATS_LABEL_ATTRIBUTE},
                {displayed_text, STATS_GOOD_ATTRIBUTE},
                {"  MISS ", STATS_LABEL_ATTRIBUTE},
                {missing_text, fpga.missing_stripes == 0
                                   ? STATS_GOOD_ATTRIBUTE
                                   : STATS_ERROR_ATTRIBUTE},
                {"  ENH ", STATS_LABEL_ATTRIBUTE},
                {enhancement_text, STATS_VALUE_ATTRIBUTE},
                {"  BAD ", STATS_LABEL_ATTRIBUTE},
                {bad2_text, decoder_bad == 0
                                ? STATS_GOOD_ATTRIBUTE
                                : STATS_ERROR_ATTRIBUTE},
            };
            (void)receiver_osd_write_spans(
                3, row3, sizeof(row3) / sizeof(row3[0]));
        } else {
            const receiver_osd_span_t error_row[] = {
                {"FPGA SPI", STATS_TITLE_ATTRIBUTE},
                {" ERROR ", STATS_ERROR_ATTRIBUTE},
                {esp_err_to_name(fpga_err), STATS_VALUE_ATTRIBUTE},
            };
            (void)receiver_osd_write_spans(
                2, error_row, sizeof(error_row) / sizeof(error_row[0]));
            (void)receiver_osd_write_spans(3, NULL, 0);
        }

        xTaskDelayUntil(&wake_time, pdMS_TO_TICKS(1000));
    }
}

bool receiver_osd_is_running(void)
{
    return s_running;
}


esp_err_t receiver_osd_set_test_pattern(uint8_t mode)
{
    if (!s_running || s_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (mode > 3) {
        return ESP_ERR_INVALID_ARG;
    }
    if (xSemaphoreTake(s_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    const uint8_t command[] = {CMD_TEST_PATTERN, mode};
    const esp_err_t err = spi_write(command, sizeof(command));
    xSemaphoreGive(s_mutex);
    return err;
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

    uint8_t status[11] = {0};
    // CDONE only means that configuration has finished. The two FPGA PLLs
    // and their reset synchronizers can still be settling, so wait for the
    // user SPI endpoint instead of permanently failing on the first read.
    for (unsigned attempt = 0; attempt < 50; ++attempt) {
        err = spi_read_command(CMD_READ_STATUS, status, sizeof(status));
        if (err != ESP_OK ||
            (status[0] == OSD_PROTOCOL_SIGNATURE &&
             status[1] == OSD_PROTOCOL_VERSION)) {
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (err == ESP_OK && (status[0] != OSD_PROTOCOL_SIGNATURE ||
                          status[1] != OSD_PROTOCOL_VERSION)) {
        ESP_LOGE(TAG, "FPGA status mismatch: signature=%02x version=%02x flags=%02x",
                 status[0], status[1], status[2]);
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
    if (err == ESP_OK) {
        const uint8_t pattern[] = {CMD_TEST_PATTERN, 1};
        err = spi_write(pattern, sizeof(pattern));
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
