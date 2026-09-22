#include "decoder_test_stream.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "board_pins.h"
#include "driver/parlio_tx.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TEST_STREAM_HEADER_SIZE 16
#define TEST_STREAM_MAX_RECORD_SIZE 1024
#define TEST_STREAM_CLOCK_HZ (24 * 1000 * 1000)
#define TEST_STREAM_QUEUE_DEPTH 16

typedef struct {
    uint16_t size;
    uint8_t *data;
} test_stream_record_t;

static const uint8_t TEST_STREAM_MAGIC[8] = {
    'H', 'D', 'Z', 'R', 'X', 'T', '1', '\0',
};

static const char *TAG = "decoder_test";
static parlio_tx_unit_handle_t s_tx_unit;
static TaskHandle_t s_task;
static volatile bool s_stop_requested;
static char s_path[160];
static decoder_test_stream_status_t s_status;

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static bool read_exact(FILE *file, void *data, size_t size)
{
    return fread(data, 1, size, file) == size;
}

static esp_err_t read_header(FILE *file, uint16_t *record_count,
                             uint16_t *maximum_record_size)
{
    uint8_t header[TEST_STREAM_HEADER_SIZE];
    if (!read_exact(file, header, sizeof(header))) {
        return ESP_ERR_INVALID_SIZE;
    }
    if (memcmp(header, TEST_STREAM_MAGIC, sizeof(TEST_STREAM_MAGIC)) != 0) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    *record_count = read_le16(header + 8);
    *maximum_record_size = read_le16(header + 10);
    if (*record_count == 0 || *maximum_record_size < 20 ||
        *maximum_record_size > TEST_STREAM_MAX_RECORD_SIZE) {
        return ESP_ERR_INVALID_SIZE;
    }
    return ESP_OK;
}

static esp_err_t open_and_validate(const char *path, FILE **result,
                                   uint16_t *record_count,
                                   uint16_t *maximum_record_size)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    const esp_err_t err = read_header(file, record_count, maximum_record_size);
    if (err != ESP_OK) {
        fclose(file);
        return err;
    }
    *result = file;
    return ESP_OK;
}

static void stream_task(void *argument)
{
    (void)argument;
    uint16_t record_count = 0;
    uint16_t maximum_record_size = 0;
    FILE *file = NULL;
    esp_err_t err = open_and_validate(s_path, &file, &record_count,
                                      &maximum_record_size);
    test_stream_record_t *records = NULL;
    if (err == ESP_OK) {
        records = calloc(record_count, sizeof(*records));
        if (records == NULL) {
            err = ESP_ERR_NO_MEM;
        }
    }

    // Keep every payload alive for the whole test. PARLIO can then queue
    // several DMA transactions while the FPGA controls the actual rate by
    // gating its external PAR_CLK when the ingress FIFO approaches full.
    for (uint16_t index = 0; err == ESP_OK && index < record_count; ++index) {
        uint8_t size_bytes[2];
        if (!read_exact(file, size_bytes, sizeof(size_bytes))) {
            err = ESP_ERR_INVALID_SIZE;
            break;
        }
        const uint16_t size = read_le16(size_bytes);
        if (size < 20 || size > maximum_record_size) {
            err = ESP_ERR_INVALID_SIZE;
            break;
        }
        records[index].data = heap_caps_malloc(
            size, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        if (records[index].data == NULL) {
            err = ESP_ERR_NO_MEM;
            break;
        }
        records[index].size = size;
        if (!read_exact(file, records[index].data, size)) {
            err = ESP_ERR_INVALID_SIZE;
        }
    }
    if (file != NULL) {
        fclose(file);
        file = NULL;
    }

    const parlio_transmit_config_t transmit_config = {
        .idle_value = 0,
    };
    while (err == ESP_OK && !s_stop_requested) {
        for (uint16_t index = 0;
             index < record_count && !s_stop_requested; ++index) {
            err = parlio_tx_unit_transmit(s_tx_unit, records[index].data,
                                          records[index].size * 8,
                                          &transmit_config);
            if (err != ESP_OK) {
                break;
            }
            ++s_status.records_sent;
            s_status.bytes_sent += records[index].size;
        }
        if (err == ESP_OK) {
            // One wait per complete frame replaces 101 waits per frame. The
            // queued buffers are immutable, so they remain DMA-safe here.
            err = parlio_tx_unit_wait_all_done(s_tx_unit, 2000);
        }
        if (err != ESP_OK || s_stop_requested) {
            break;
        }
        ++s_status.passes;
        if (!s_status.loop) {
            break;
        }
    }

    if (file != NULL) {
        fclose(file);
    }
    if (records != NULL) {
        for (uint16_t index = 0; index < record_count; ++index) {
            free(records[index].data);
        }
        free(records);
    }
    s_status.last_error = err;
    s_status.running = false;
    s_task = NULL;
    ESP_LOGI(TAG, "stream stopped: passes=%lu records=%lu bytes=%lu result=%s",
             (unsigned long)s_status.passes,
             (unsigned long)s_status.records_sent,
             (unsigned long)s_status.bytes_sent, esp_err_to_name(err));
    vTaskDelete(NULL);
}

esp_err_t decoder_test_stream_start(const char *path, bool loop)
{
    if (path == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_status.running) {
        return ESP_ERR_INVALID_STATE;
    }
    const size_t path_length = strlen(path);
    if (path_length == 0 || path_length >= sizeof(s_path)) {
        return ESP_ERR_INVALID_ARG;
    }

    FILE *probe = NULL;
    uint16_t record_count = 0;
    uint16_t maximum_record_size = 0;
    esp_err_t err = open_and_validate(path, &probe, &record_count,
                                      &maximum_record_size);
    if (err != ESP_OK) {
        return err;
    }
    fclose(probe);

    if (s_tx_unit == NULL) {
        const parlio_tx_unit_config_t config = {
            .clk_src = PARLIO_CLK_SRC_EXTERNAL,
            .clk_in_gpio_num = BOARD_PIN_PAR_CLK,
            .input_clk_src_freq_hz = TEST_STREAM_CLOCK_HZ,
            .output_clk_freq_hz = TEST_STREAM_CLOCK_HZ,
            .data_width = 4,
            .data_gpio_nums = {
                BOARD_PIN_PAR_D0, BOARD_PIN_PAR_D1,
                BOARD_PIN_PAR_D2, BOARD_PIN_PAR_D3,
            },
            .clk_out_gpio_num = -1,
            .valid_gpio_num = BOARD_PIN_PAR_CS,
            .trans_queue_depth = TEST_STREAM_QUEUE_DEPTH,
            .max_transfer_size = TEST_STREAM_MAX_RECORD_SIZE,
            .dma_burst_size = 32,
            .shift_edge = PARLIO_SHIFT_EDGE_NEG,
            .bit_pack_order = PARLIO_BIT_PACK_ORDER_MSB,
        };
        err = parlio_new_tx_unit(&config, &s_tx_unit);
        if (err != ESP_OK) {
            return err;
        }
        err = parlio_tx_unit_enable(s_tx_unit);
        if (err != ESP_OK) {
            parlio_del_tx_unit(s_tx_unit);
            s_tx_unit = NULL;
            return err;
        }
    }

    memcpy(s_path, path, path_length + 1);
    s_stop_requested = false;
    s_status = (decoder_test_stream_status_t) {
        .running = true,
        .loop = loop,
        .last_error = ESP_OK,
    };
    if (xTaskCreate(stream_task, "decoder_file", 4096, NULL, 8, &s_task) !=
        pdPASS) {
        s_status.running = false;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "playing %s: %u records, max %u bytes, loop=%u", path,
             record_count, maximum_record_size, loop);
    return ESP_OK;
}

esp_err_t decoder_test_stream_stop(void)
{
    if (!s_status.running) {
        return ESP_ERR_INVALID_STATE;
    }
    s_stop_requested = true;
    for (unsigned wait = 0; wait < 250 && s_status.running; ++wait) {
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    return s_status.running ? ESP_ERR_TIMEOUT : ESP_OK;
}

void decoder_test_stream_get_status(decoder_test_stream_status_t *status)
{
    if (status != NULL) {
        *status = s_status;
    }
}
