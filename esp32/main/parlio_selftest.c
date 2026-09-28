#include "parlio_selftest.h"
#include "board_pins.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "driver/parlio_rx.h"
#include "esp_attr.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#define SELFTEST_RECORDS 16U
#define SELFTEST_BUFFER_BYTES 1024U
#define SELFTEST_DATA0_GPIO BOARD_PIN_PAR_D0
#define SELFTEST_DATA1_GPIO BOARD_PIN_PAR_D1
#define SELFTEST_DATA2_GPIO BOARD_PIN_PAR_D2
#define SELFTEST_DATA3_GPIO BOARD_PIN_PAR_D3
#define SELFTEST_CLOCK_GPIO BOARD_PIN_PAR_CLK
#define SELFTEST_VALID_GPIO BOARD_PIN_PAR_CS

typedef struct {
    void *data;
    size_t bytes;
} selftest_event_t;

typedef struct {
    TaskHandle_t waiter;
    volatile bool stop;
} selftest_sender_context_t;

static const char *TAG = "parlio_selftest";

static const uint16_t s_lengths[SELFTEST_RECORDS] = {
    20, 21, 22, 23, 31, 47, 64, 127,
    20, 21, 22, 23, 31, 47, 64, 127,
};

static uint8_t expected_byte(size_t record, size_t offset)
{
    return (uint8_t)(0xa5U ^ (record * 0x31U) ^
                     (offset * 0x1dU) ^ (offset >> 3));
}

static void send_nibble(uint8_t nibble)
{
    gpio_set_level(SELFTEST_DATA0_GPIO, nibble & 1U);
    gpio_set_level(SELFTEST_DATA1_GPIO, (nibble >> 1) & 1U);
    gpio_set_level(SELFTEST_DATA2_GPIO, (nibble >> 2) & 1U);
    gpio_set_level(SELFTEST_DATA3_GPIO, (nibble >> 3) & 1U);
    esp_rom_delay_us(2);
    gpio_set_level(SELFTEST_CLOCK_GPIO, 1);
    esp_rom_delay_us(2);
    gpio_set_level(SELFTEST_CLOCK_GPIO, 0);
}

static void selftest_sender(void *argument)
{
    selftest_sender_context_t *context = argument;
    vTaskDelay(pdMS_TO_TICKS(20));
    for (size_t record = 0;
         record < SELFTEST_RECORDS && !context->stop; ++record) {
        gpio_set_level(SELFTEST_VALID_GPIO, 0);
        esp_rom_delay_us(4);
        for (size_t offset = 0; offset < s_lengths[record]; ++offset) {
            const uint8_t value = expected_byte(record, offset);
            send_nibble(value >> 4);
            send_nibble(value & 0x0fU);
        }
        for (size_t offset = s_lengths[record];
             offset < SELFTEST_BUFFER_BYTES; ++offset) {
            send_nibble(0);
            send_nibble(0);
        }
        esp_rom_delay_us(2);
        gpio_set_level(SELFTEST_VALID_GPIO, 1);
        send_nibble(0);
        esp_rom_delay_us(50);
    }
    xTaskNotifyGive(context->waiter);
    vTaskDelete(NULL);
}

static bool IRAM_ATTR selftest_done_callback(
    parlio_rx_unit_handle_t unit,
    const parlio_rx_event_data_t *event,
    void *user_data)
{
    (void)unit;
    const selftest_event_t message = {
        .data = event->data,
        .bytes = event->recv_bytes,
    };
    BaseType_t task_woken = pdFALSE;
    xQueueSendFromISR((QueueHandle_t)user_data, &message, &task_woken);
    return task_woken == pdTRUE;
}


esp_err_t parlio_variable_length_selftest(void)
{
    gpio_set_level(BOARD_PIN_FPGA_CRESET, 0);
    vTaskDelay(pdMS_TO_TICKS(2));
    esp_err_t result = ESP_OK;
    parlio_rx_unit_handle_t unit = NULL;
    parlio_rx_delimiter_handle_t delimiter = NULL;
    QueueHandle_t event_queue = NULL;
    TaskHandle_t sender_task = NULL;
    uint8_t *buffers[SELFTEST_RECORDS] = {0};
    selftest_sender_context_t sender = {
        .waiter = xTaskGetCurrentTaskHandle(),
    };

    const gpio_config_t pre_output_config = {
        .pin_bit_mask = BIT64(SELFTEST_DATA0_GPIO) |
                        BIT64(SELFTEST_DATA1_GPIO) |
                        BIT64(SELFTEST_DATA2_GPIO) |
                        BIT64(SELFTEST_DATA3_GPIO) |
                        BIT64(SELFTEST_CLOCK_GPIO) |
                        BIT64(SELFTEST_VALID_GPIO),
        .mode = GPIO_MODE_INPUT_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    result = gpio_config(&pre_output_config);
    if (result != ESP_OK) {
        goto cleanup;
    }

    const parlio_rx_unit_config_t unit_config = {
        .trans_queue_depth = SELFTEST_RECORDS,
        .max_recv_size = SELFTEST_BUFFER_BYTES,
        .dma_burst_size = 32,
        .data_width = 4,
        .clk_src = PARLIO_CLK_SRC_EXTERNAL,
        .ext_clk_freq_hz = 250000,
        .exp_clk_freq_hz = 250000,
        .clk_in_gpio_num = SELFTEST_CLOCK_GPIO,
        .clk_out_gpio_num = -1,
        .valid_gpio_num = SELFTEST_VALID_GPIO,
        .data_gpio_nums = {
            SELFTEST_DATA0_GPIO, SELFTEST_DATA1_GPIO,
            SELFTEST_DATA2_GPIO, SELFTEST_DATA3_GPIO,
            [4 ... (PARLIO_RX_UNIT_MAX_DATA_WIDTH - 1)] = -1,
        },
        .flags = {
            .free_clk = false,
            .clk_gate_en = false,
        },
    };
    result = parlio_new_rx_unit(&unit_config, &unit);
    if (result != ESP_OK) {
        goto cleanup;
    }

    const parlio_rx_level_delimiter_config_t delimiter_config = {
        .valid_sig_line_id = PARLIO_RX_UNIT_MAX_DATA_WIDTH - 1,
        .sample_edge = PARLIO_SAMPLE_EDGE_POS,
        .bit_pack_order = PARLIO_BIT_PACK_ORDER_MSB,
        .eof_data_len = SELFTEST_BUFFER_BYTES,
        .timeout_ticks = 0,
        .flags = {
            .active_low_en = true,
        },
    };
    result = parlio_new_rx_level_delimiter(&delimiter_config, &delimiter);
    if (result != ESP_OK) {
        goto cleanup;
    }

    event_queue = xQueueCreate(SELFTEST_RECORDS, sizeof(selftest_event_t));
    if (event_queue == NULL) {
        result = ESP_ERR_NO_MEM;
        goto cleanup;
    }
    const parlio_rx_event_callbacks_t callbacks = {
        .on_receive_done = selftest_done_callback,
    };
    result = parlio_rx_unit_register_event_callbacks(
        unit, &callbacks, event_queue);
    if (result != ESP_OK) {
        goto cleanup;
    }
    result = parlio_rx_unit_enable(unit, true);
    if (result != ESP_OK) {
        goto cleanup;
    }

    const parlio_receive_config_t receive_config = {
        .delimiter = delimiter,
        .flags = {
            .partial_rx_en = false,
            .indirect_mount = false,
        },
    };
    for (size_t index = 0; index < SELFTEST_RECORDS; ++index) {
        buffers[index] = heap_caps_aligned_alloc(
            32, SELFTEST_BUFFER_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        if (buffers[index] == NULL) {
            result = ESP_ERR_NO_MEM;
            goto cleanup;
        }
        result = parlio_rx_unit_receive(
            unit, buffers[index], SELFTEST_BUFFER_BYTES, &receive_config);
        if (result != ESP_OK) {
            goto cleanup;
        }
    }

    gpio_set_level(SELFTEST_CLOCK_GPIO, 0);
    gpio_set_level(SELFTEST_VALID_GPIO, 1);
    gpio_set_level(SELFTEST_DATA0_GPIO, 0);
    gpio_set_level(SELFTEST_DATA1_GPIO, 0);
    gpio_set_level(SELFTEST_DATA2_GPIO, 0);
    gpio_set_level(SELFTEST_DATA3_GPIO, 0);

    if (xTaskCreate(selftest_sender, "parlio_pattern", 3072, &sender, 5,
                    &sender_task) != pdPASS) {
        sender_task = NULL;
        result = ESP_ERR_NO_MEM;
        goto cleanup;
    }

    for (size_t record = 0; record < SELFTEST_RECORDS; ++record) {
        selftest_event_t event;
        if (xQueueReceive(event_queue, &event,
                          pdMS_TO_TICKS(2000)) != pdTRUE) {
            ESP_LOGE(TAG, "timeout waiting for record %u", (unsigned)record);
            result = ESP_ERR_TIMEOUT;
            goto cleanup;
        }
        if (event.bytes != SELFTEST_BUFFER_BYTES) {
            ESP_LOGE(TAG, "record %u length=%u expected=%u",
                     (unsigned)record, (unsigned)event.bytes,
                     SELFTEST_BUFFER_BYTES);
            result = ESP_ERR_INVALID_SIZE;
            goto cleanup;
        }
        const uint8_t *data = event.data;
        for (size_t offset = 0; offset < event.bytes; ++offset) {
            const uint8_t expected = offset < s_lengths[record]
                                         ? expected_byte(record, offset) : 0;
            if (data[offset] != expected) {
                ESP_LOGE(TAG,
                         "record %u byte %u value=%02x expected=%02x",
                         (unsigned)record, (unsigned)offset,
                         data[offset], expected);
                result = ESP_ERR_INVALID_RESPONSE;
                goto cleanup;
            }
        }
        ESP_LOGI(TAG, "record %u okay, logical=%u wire=%u",
                 (unsigned)record, (unsigned)s_lengths[record],
                 (unsigned)event.bytes);

    }

cleanup:
    if (sender_task != NULL) {
        sender.stop = true;
        if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000)) == 0) {
            vTaskDelete(sender_task);
        }
    }
    gpio_set_level(SELFTEST_VALID_GPIO, 0);
    gpio_set_level(SELFTEST_CLOCK_GPIO, 0);
    if (unit != NULL) {
        parlio_rx_unit_disable(unit);
    }
    if (delimiter != NULL) {
        parlio_del_rx_delimiter(delimiter);
    }
    if (unit != NULL) {
        parlio_del_rx_unit(unit);
    }
    for (size_t index = 0; index < SELFTEST_RECORDS; ++index) {
        heap_caps_free(buffers[index]);
    }
    if (event_queue != NULL) {
        vQueueDelete(event_queue);
    }
    if (result == ESP_OK) {
        ESP_LOGI(TAG, "PASS: %u variable-length 4-bit records",
                 SELFTEST_RECORDS);
    }
    return result;
}
