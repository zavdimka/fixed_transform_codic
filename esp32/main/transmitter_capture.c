#include "transmitter_capture.h"
#include "transmitter_diag.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "board_pins.h"
#include "driver/parlio_rx.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#define CAPTURE_STORAGE_BYTES (6U * 1024U * 1024U)
#define CAPTURE_RECORD_BYTES 2048U
#define CAPTURE_WIRE_BYTES 1420U
#define CAPTURE_DMA_BUFFERS 16U
#define CAPTURE_WAIT_MS 180000U
#define CAPTURE_MAGIC "HDZCAP1"
#define CAPTURE_HEADER_BYTES 24U

typedef struct {
    void *data;
    size_t bytes;
} capture_event_t;

static const char *TAG = "tx_capture";
static uint8_t *s_capture;
static size_t s_capture_size;
static size_t s_capture_capacity;
static size_t s_packet_count;
static volatile size_t s_header_errors;
static volatile size_t s_crc_errors;
static volatile size_t s_queue_overflows;
static volatile size_t s_size_errors;
static size_t s_rotated_records;
static uint8_t s_first_bad[32];
static uint8_t s_first_bad_tail[32];
static size_t s_first_bad_length;
static size_t s_first_bad_tail_length;
static size_t s_first_bad_event_bytes;
static esp_err_t s_last_error = ESP_ERR_INVALID_STATE;
static QueueHandle_t s_event_queue;

typedef struct {
    uint8_t data[CAPTURE_RECORD_BYTES];
    size_t length;
} record_assembler_t;

static size_t dropped_event_count(void)
{
    return s_header_errors + s_crc_errors + s_queue_overflows + s_size_errors;
}

static void remember_first_bad(const uint8_t *data, size_t size)
{
    if (s_first_bad_length != 0 || size == 0) {
        return;
    }
    s_first_bad_event_bytes = size;
    s_first_bad_length = size < sizeof(s_first_bad) ? size : sizeof(s_first_bad);
    s_first_bad_tail_length =
        size < sizeof(s_first_bad_tail) ? size : sizeof(s_first_bad_tail);
    memcpy(s_first_bad, data, s_first_bad_length);
    memcpy(s_first_bad_tail, data + size - s_first_bad_tail_length,
           s_first_bad_tail_length);
}

static void write_le16(uint8_t *destination, uint16_t value)
{
    destination[0] = value & 0xff;
    destination[1] = value >> 8;
}

static void write_le32(uint8_t *destination, uint32_t value)
{
    destination[0] = value & 0xff;
    destination[1] = (value >> 8) & 0xff;
    destination[2] = (value >> 16) & 0xff;
    destination[3] = value >> 24;
}

static uint16_t read_le16(const uint8_t *source)
{
    return (uint16_t)source[0] | ((uint16_t)source[1] << 8);
}

static uint16_t crc16_ccitt(const uint8_t *data, size_t size)
{
    uint16_t crc = 0xffff;
    while (size-- != 0) {
        crc ^= (uint16_t)*data++ << 8;
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x8000U) != 0
                      ? (uint16_t)((crc << 1) ^ 0x1021U)
                      : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t size)
{
    while (size-- != 0) {
        crc ^= *data++;
        for (unsigned bit = 0; bit < 8; ++bit) {
            const uint32_t mask = 0U - (crc & 1U);
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & mask);
        }
    }
    return crc;
}

static esp_err_t store_record(const record_assembler_t *record)
{
    const bool header_invalid =
        record->length < 20 || record->data[0] != 0xc5 || record->data[1] != 0x3a ||
        record->data[2] != 0x01 ||
        record->length != 20U + read_le16(record->data + 16);
    const bool crc_invalid = !header_invalid &&
        crc16_ccitt(record->data, record->length - 2) !=
            read_le16(record->data + record->length - 2);
    if (header_invalid || crc_invalid) {
        remember_first_bad(record->data, record->length);
        if (header_invalid) {
            ++s_header_errors;
        } else {
            ++s_crc_errors;
        }
        return ESP_OK;
    }
    const size_t entry_size = 2 + record->length;
    if (entry_size > s_capture_capacity - s_capture_size) {
        return ESP_ERR_NO_MEM;
    }
    write_le16(s_capture + s_capture_size, (uint16_t)record->length);
    memcpy(s_capture + s_capture_size + 2, record->data, record->length);
    s_capture_size += entry_size;
    ++s_packet_count;
    return ESP_OK;
}

static esp_err_t consume_record(
    const uint8_t *data, size_t size,
    parlio_rx_unit_handle_t unit,
    const parlio_receive_config_t *receive_config)
{
    if (size > CAPTURE_RECORD_BYTES) {
        ++s_size_errors;
        remember_first_bad(data, size);
        return ESP_ERR_INVALID_SIZE;
    }
    record_assembler_t record = {
        .length = size,
    };
    memcpy(record.data, data, size);


    if (record.data[0] == 0xc5 && record.data[1] == 0x3a &&
        record.data[2] == 0x01) {
        const size_t encoded_size = 20U + read_le16(record.data + 16);
        if (encoded_size <= size) {
            record.length = encoded_size;
        }
    }

    // Return the DMA buffer immediately after taking a private copy. At the
    // 6 MHz wire rate, parsing and PSRAM writes must not create a
    // hole in the prequeued receive ring.
    const esp_err_t requeue_error = parlio_rx_unit_receive(
        unit, (void *)data, CAPTURE_RECORD_BYTES, receive_config);
    if (requeue_error != ESP_OK) {
        return requeue_error;
    }

    return store_record(&record);
}
static bool IRAM_ATTR capture_done_callback(
    parlio_rx_unit_handle_t unit,
    const parlio_rx_event_data_t *event,
    void *user_data)
{
    (void)unit;
    (void)user_data;
    const capture_event_t message = {
        .data = event->data,
        .bytes = event->recv_bytes,
    };
    BaseType_t task_woken = pdFALSE;
    if (xQueueSendFromISR(s_event_queue, &message, &task_woken) != pdTRUE) {
        ++s_queue_overflows;
    }
    return task_woken == pdTRUE;
}


static void release_hardware(parlio_rx_unit_handle_t unit,
                             parlio_rx_delimiter_handle_t delimiter,
                             uint8_t *dma_buffers[CAPTURE_DMA_BUFFERS])
{
    if (unit != NULL) {
        parlio_rx_unit_disable(unit);
    }
    if (delimiter != NULL) {
        parlio_del_rx_delimiter(delimiter);
    }

    if (unit != NULL) {
        parlio_del_rx_unit(unit);
    }
    for (size_t index = 0; index < CAPTURE_DMA_BUFFERS; ++index) {
        heap_caps_free(dma_buffers[index]);
    }
    if (s_event_queue != NULL) {
        vQueueDelete(s_event_queue);
        s_event_queue = NULL;
    }
}

esp_err_t transmitter_capture_run(size_t packet_limit)
{
    if (packet_limit == 0 || packet_limit > 20000) {
        return ESP_ERR_INVALID_ARG;
    }

    const size_t requested_bytes = CAPTURE_HEADER_BYTES +
        packet_limit * (CAPTURE_WIRE_BYTES + 2U);
    const size_t capture_bytes = requested_bytes < CAPTURE_STORAGE_BYTES
                                     ? requested_bytes
                                     : CAPTURE_STORAGE_BYTES;
    uint8_t *new_capture = heap_caps_malloc(
        capture_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (new_capture == NULL) {
        return ESP_ERR_NO_MEM;
    }
    heap_caps_free(s_capture);
    s_capture = new_capture;
    s_capture_capacity = capture_bytes;
    s_capture_size = 0;
    s_packet_count = 0;
    s_header_errors = 0;
    s_crc_errors = 0;
    s_queue_overflows = 0;
    s_size_errors = 0;
    s_rotated_records = 0;
    s_first_bad_length = 0;
    s_first_bad_tail_length = 0;
    s_first_bad_event_bytes = 0;
    s_last_error = ESP_OK;

    parlio_rx_unit_handle_t unit = NULL;
    parlio_rx_delimiter_handle_t delimiter = NULL;
    uint8_t *dma_buffers[CAPTURE_DMA_BUFFERS] = {0};
    s_event_queue = xQueueCreate(
        CAPTURE_DMA_BUFFERS * 2, sizeof(capture_event_t));
    if (s_event_queue == NULL) {
        s_last_error = ESP_ERR_NO_MEM;
        goto cleanup;
    }

    parlio_rx_unit_config_t unit_config = {
        .trans_queue_depth = CAPTURE_DMA_BUFFERS,
        .max_recv_size = CAPTURE_RECORD_BYTES,
        .dma_burst_size = 32,
        .data_width = 4,
        .clk_src = PARLIO_CLK_SRC_EXTERNAL,
        .ext_clk_freq_hz = 24U * 1000U * 1000U,
        .exp_clk_freq_hz = 24U * 1000U * 1000U,
        .clk_in_gpio_num = BOARD_PIN_PAR_CLK,
        .clk_out_gpio_num = -1,
        .valid_gpio_num = BOARD_PIN_PAR_CS,
        .flags = {
            .free_clk = false,
            .clk_gate_en = false,
        },
    };
    for (size_t index = 0; index < PARLIO_RX_UNIT_MAX_DATA_WIDTH; ++index) {
        unit_config.data_gpio_nums[index] = -1;
    }
    unit_config.data_gpio_nums[0] = BOARD_PIN_PAR_D0;
    unit_config.data_gpio_nums[1] = BOARD_PIN_PAR_D1;
    unit_config.data_gpio_nums[2] = BOARD_PIN_PAR_D2;
    unit_config.data_gpio_nums[3] = BOARD_PIN_PAR_D3;

    s_last_error = parlio_new_rx_unit(&unit_config, &unit);
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }

    const parlio_rx_level_delimiter_config_t delimiter_config = {
        .valid_sig_line_id = PARLIO_RX_UNIT_MAX_DATA_WIDTH - 1,
        .sample_edge = PARLIO_SAMPLE_EDGE_POS,
        .bit_pack_order = PARLIO_BIT_PACK_ORDER_MSB,
        // All steady-state DMA transactions have the fixed wire-record size.
        .eof_data_len = CAPTURE_WIRE_BYTES,
        .timeout_ticks = 0,
        .flags = {
            .active_low_en = false,
        },
    };
    s_last_error = parlio_new_rx_level_delimiter(
        &delimiter_config, &delimiter);
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }


    const parlio_rx_event_callbacks_t callbacks = {
        .on_receive_done = capture_done_callback,
    };
    s_last_error = parlio_rx_unit_register_event_callbacks(
        unit, &callbacks, NULL);
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }
    s_last_error = parlio_rx_unit_enable(unit, true);
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }
    const parlio_receive_config_t receive_config = {
        .delimiter = delimiter,
        .flags = {
            .partial_rx_en = false,
            .indirect_mount = false,
        },
    };

    for (size_t index = 0; index < CAPTURE_DMA_BUFFERS; ++index) {
        dma_buffers[index] = heap_caps_aligned_alloc(
            32, CAPTURE_RECORD_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        if (dma_buffers[index] == NULL) {
            s_last_error = ESP_ERR_NO_MEM;
            goto cleanup;
        }
        s_last_error = parlio_rx_unit_receive(
            unit, dma_buffers[index], CAPTURE_RECORD_BYTES, &receive_config);
        if (s_last_error != ESP_OK) {
            goto cleanup;
        }
    }


    // Arm the FPGA only after PARLIO has receive descriptors ready. The
    // transmitter emits a finite camera frame, so arming it before this point
    // can put the complete variable-length stream on the wire before RX starts.
    s_last_error = transmitter_diag_arm_capture();
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }

    // Sacrifice the first complete wire record while PARLIO enters streaming
    // state. Every steady-state DMA transaction then starts in the following
    // inter-record gap; no bytes from this record enter the captured stream.
    capture_event_t startup_event;
    if (xQueueReceive(s_event_queue, &startup_event,
                      pdMS_TO_TICKS(1000)) != pdTRUE) {
        s_last_error = ESP_ERR_TIMEOUT;
        goto cleanup;
    }
    if (startup_event.bytes != CAPTURE_WIRE_BYTES) {
        ++s_size_errors;
        remember_first_bad(startup_event.data, startup_event.bytes);
        s_last_error = ESP_ERR_INVALID_SIZE;
        goto cleanup;
    }
    s_last_error = parlio_rx_unit_receive(
        unit, startup_event.data, CAPTURE_RECORD_BYTES, &receive_config);
    if (s_last_error != ESP_OK) {
        goto cleanup;
    }
    ESP_LOGI(TAG, "discarded startup transaction: bytes=%u",
             (unsigned)startup_event.bytes);

    ESP_LOGI(TAG, "capturing up to %u complete packets into %u-byte PSRAM buffer",
             (unsigned)packet_limit, (unsigned)s_capture_capacity);
    const TickType_t capture_start = xTaskGetTickCount();
    TickType_t next_progress_report = capture_start + pdMS_TO_TICKS(1000);
    while (s_packet_count < packet_limit) {
        const TickType_t now = xTaskGetTickCount();
        if (now - capture_start > pdMS_TO_TICKS(CAPTURE_WAIT_MS)) {
            s_last_error = ESP_ERR_TIMEOUT;
            break;
        }
        if (now >= next_progress_report) {
            ESP_LOGI(TAG, "RX progress: packets=%u queue=%u",
                     (unsigned)s_packet_count,
                     (unsigned)uxQueueMessagesWaiting(s_event_queue));
            transmitter_diag_print_status();
            next_progress_report = now + pdMS_TO_TICKS(1000);
        }
        capture_event_t event;
        if (xQueueReceive(s_event_queue, &event,
                          pdMS_TO_TICKS(100)) != pdTRUE) {
            continue;
        }
        if (event.bytes == 0 || event.bytes > CAPTURE_RECORD_BYTES) {
            s_last_error = ESP_ERR_INVALID_SIZE;
            break;
        }
        s_last_error = consume_record(
            event.data, event.bytes, unit, &receive_config);
        if (s_last_error != ESP_OK) {
            break;
        }

    }

cleanup:
    release_hardware(unit, delimiter, dma_buffers);
    if (s_packet_count != 0 &&
        (s_last_error == ESP_ERR_TIMEOUT || s_last_error == ESP_ERR_NO_MEM)) {
        ESP_LOGW(TAG, "partial capture retained: packets=%u bytes=%u (%s)",
                 (unsigned)s_packet_count, (unsigned)s_capture_size,
                 esp_err_to_name(s_last_error));
    } else if (s_last_error == ESP_OK) {
        ESP_LOGI(TAG, "capture complete: packets=%u bytes=%u",
                 (unsigned)s_packet_count, (unsigned)s_capture_size);
    }
    ESP_LOGI(TAG, "transport: rotated=%u header=%u crc=%u queue=%u size=%u",
             (unsigned)s_rotated_records, (unsigned)s_header_errors,
             (unsigned)s_crc_errors, (unsigned)s_queue_overflows,
             (unsigned)s_size_errors);
    if (s_first_bad_length != 0) {
        ESP_LOGI(TAG, "first bad transaction: bytes=%u, first %u bytes:",
                 (unsigned)s_first_bad_event_bytes,
                 (unsigned)s_first_bad_length);
        ESP_LOG_BUFFER_HEX_LEVEL(TAG, s_first_bad, s_first_bad_length,
                                 ESP_LOG_INFO);
        ESP_LOGI(TAG, "last %u bytes:", (unsigned)s_first_bad_tail_length);
        ESP_LOG_BUFFER_HEX_LEVEL(TAG, s_first_bad_tail,
                                 s_first_bad_tail_length, ESP_LOG_INFO);
    }
    return s_last_error;
}

static size_t dump_bytes(const uint8_t *data, size_t size)
{
    size_t total = 0;
    unsigned stalled_writes = 0;
    while (total < size && stalled_writes < 10000) {
        size_t chunk = size - total;
        if (chunk > 4096) {
            chunk = 4096;
        }
        const size_t written = fwrite(data + total, 1, chunk, stdout);
        if (written == 0) {
            // The nonblocking USB VFS can temporarily report EAGAIN when its
            // 256-byte TX ring is full. Clear stdio's sticky error and retry.
            clearerr(stdout);
            ++stalled_writes;
            vTaskDelay(1);
            continue;
        }
        total += written;
        stalled_writes = 0;
        if (written != chunk) {
            clearerr(stdout);
        }
        fflush(stdout);
        // A multi-megabyte dump otherwise monopolizes the console task long
        // enough to starve the USB Serial/JTAG writer and the task watchdog.
        vTaskDelay(1);
    }
    return total;
}

esp_err_t transmitter_capture_dump(void)
{
    if (s_capture == NULL || s_packet_count == 0) {
        return ESP_ERR_INVALID_STATE;
    }

    uint8_t header[CAPTURE_HEADER_BYTES] = {0};
    memcpy(header, CAPTURE_MAGIC, 7);
    header[7] = 0;
    write_le32(header + 8, 1);
    write_le32(header + 12, (uint32_t)s_packet_count);
    write_le32(header + 16, (uint32_t)s_capture_size);
    uint32_t payload_crc = crc32_update(
        UINT32_C(0xffffffff), s_capture, s_capture_size) ^ UINT32_C(0xffffffff);
    write_le32(header + 20, payload_crc);

    uint32_t transfer_crc = crc32_update(
        UINT32_C(0xffffffff), header, sizeof(header));
    transfer_crc = crc32_update(transfer_crc, s_capture, s_capture_size);
    transfer_crc ^= UINT32_C(0xffffffff);
    const size_t transfer_size = sizeof(header) + s_capture_size;

    esp_log_level_set("*", ESP_LOG_NONE);
    usb_serial_jtag_vfs_set_tx_line_endings(ESP_LINE_ENDINGS_LF);
    printf("CAPTURE READY size=%u crc=%08x\n",
           (unsigned)transfer_size, (unsigned)transfer_crc);
    fflush(stdout);
    const size_t header_written = dump_bytes(header, sizeof(header));
    const size_t payload_written = dump_bytes(s_capture, s_capture_size);
    fflush(stdout);
    vTaskDelay(pdMS_TO_TICKS(100));
    printf("\nCAPTURE DONE\n");
    fflush(stdout);
    usb_serial_jtag_vfs_set_tx_line_endings(ESP_LINE_ENDINGS_CRLF);
    esp_log_level_set("*", ESP_LOG_INFO);

    return header_written == sizeof(header) &&
                   payload_written == s_capture_size
               ? ESP_OK
               : ESP_FAIL;
}

void transmitter_capture_get_status(transmitter_capture_status_t *status)
{
    if (status == NULL) {
        return;
    }
    *status = (transmitter_capture_status_t) {
        .packet_count = s_packet_count,
        .stored_bytes = s_capture_size,
        .capacity_bytes = s_capture == NULL ? 0 : s_capture_capacity,
        .dropped_events = dropped_event_count(),
        .header_errors = s_header_errors,
        .crc_errors = s_crc_errors,
        .queue_overflows = s_queue_overflows,
        .size_errors = s_size_errors,
        .rotated_records = s_rotated_records,
        .last_error = s_last_error,
    };
}
