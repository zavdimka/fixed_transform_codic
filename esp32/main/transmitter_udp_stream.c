#include "transmitter_udp_stream.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "board_pins.h"
#include "driver/parlio_rx.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "radio_link.h"
#include "transmitter_diag.h"

#if __has_include("wifi_secrets.h")
#include "wifi_secrets.h"
#endif

#ifndef VIDEO_WIFI_SSID
#define VIDEO_WIFI_SSID ""
#endif
#ifndef VIDEO_WIFI_PASSWORD
#define VIDEO_WIFI_PASSWORD ""
#endif
#ifndef VIDEO_UDP_DESTINATION
#define VIDEO_UDP_DESTINATION "192.168.2.131"
#endif
#ifndef VIDEO_UDP_PORT
#define VIDEO_UDP_PORT 5600
#endif

#define DMA_BUFFER_BYTES 1440U
#define WIRE_TRANSACTION_BYTES 1420U
#define DMA_BUFFER_COUNT 64U
#define UDP_SLOT_COUNT 256U
#define UDP_BATCH_BYTES 1472U
#define MAX_RECORDS_PER_FRAME 180U
#define RAW_BATCH_COALESCE_US 2000
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAILED_BIT BIT1
#define WIFI_MAXIMUM_RETRIES 10

typedef struct {
    void *data;
    size_t bytes;
} capture_event_t;

typedef struct {
    uint16_t length;
    uint8_t data[WIRE_TRANSACTION_BYTES];
} udp_slot_t;

static const char *TAG = "tx_udp";
static EventGroupHandle_t s_wifi_events;
static QueueHandle_t s_capture_events;
static QueueHandle_t s_free_slots;
static QueueHandle_t s_ready_slots;
static udp_slot_t *s_slots;
static int s_wifi_retry;
static atomic_bool s_started;
static atomic_bool s_paused;
static atomic_bool s_wifi_connected;
static app_transport_t s_transport = APP_TRANSPORT_UDP;
static atomic_uint_fast32_t s_received_records;
static atomic_uint_fast32_t s_sent_records;
static atomic_uint_fast32_t s_sent_bytes;
static atomic_uint_fast32_t s_invalid_records;
static atomic_uint_fast32_t s_queue_drops;
static atomic_uint_fast32_t s_pool_drops;
static atomic_uint_fast32_t s_send_errors;
static atomic_uint_fast32_t s_accepted_frames;
static atomic_uint_fast32_t s_dropped_frames;

static uint16_t read_le16(const uint8_t *source)
{
    return (uint16_t)source[0] | ((uint16_t)source[1] << 8);
}

static uint16_t crc16_ccitt(const uint8_t *data, size_t size)
{
    uint16_t crc = 0xffff;
    while (size-- != 0) {
        uint8_t value = (uint8_t)((crc >> 8) ^ *data++);
        value ^= value >> 4;
        crc = (uint16_t)((crc << 8) ^ ((uint16_t)value << 12) ^
                         ((uint16_t)value << 5) ^ value);
    }
    return crc;
}

static size_t encoded_record_size(const uint8_t *data, size_t size)
{
    if (size < 20 || data[0] != 0xc5 || data[1] != 0x3a ||
        data[2] != 0x01) {
        return 0;
    }
    const size_t encoded_size = 20U + read_le16(data + 16);
    if (encoded_size > size || encoded_size > WIRE_TRANSACTION_BYTES) {
        return 0;
    }
    const uint16_t expected_crc = read_le16(data + encoded_size - 2);
    return crc16_ccitt(data, encoded_size - 2) == expected_crc
               ? encoded_size
               : 0;
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
    if (xQueueSendFromISR(s_capture_events, &message, &task_woken) != pdTRUE) {
        atomic_fetch_add_explicit(&s_queue_drops, 1, memory_order_relaxed);
    }
    return task_woken == pdTRUE;
}

static void wifi_event_handler(void *argument, esp_event_base_t base,
                               int32_t event_id, void *event_data)
{
    (void)argument;
    (void)event_data;
    if (base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        atomic_store_explicit(&s_wifi_connected, false, memory_order_relaxed);
        if (s_wifi_retry++ < WIFI_MAXIMUM_RETRIES) {
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(s_wifi_events, WIFI_FAILED_BIT);
        }
    } else if (base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *got_ip = event_data;
        wifi_ap_record_t access_point = {0};
        if (esp_wifi_sta_get_ap_info(&access_point) == ESP_OK) {
            ESP_LOGI(TAG, "Wi-Fi connected, address=" IPSTR
                          " channel=%u rssi=%d",
                     IP2STR(&got_ip->ip_info.ip), access_point.primary,
                     access_point.rssi);
        } else {
            ESP_LOGI(TAG, "Wi-Fi connected, address=" IPSTR,
                     IP2STR(&got_ip->ip_info.ip));
        }
        s_wifi_retry = 0;
        atomic_store_explicit(&s_wifi_connected, true, memory_order_relaxed);
        xEventGroupSetBits(s_wifi_events, WIFI_CONNECTED_BIT);
    }
}

static esp_err_t connect_wifi(const app_config_t *app_config)
{
    if (app_config == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    s_wifi_events = xEventGroupCreate();
    if (s_wifi_events == NULL) {
        return ESP_ERR_NO_MEM;
    }
    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "esp_netif_init");
    esp_err_t err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        return err;
    }
    if (esp_netif_create_default_wifi_sta() == NULL) {
        return ESP_ERR_NO_MEM;
    }
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&init), TAG, "esp_wifi_init");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                   wifi_event_handler, NULL),
        TAG, "register Wi-Fi events");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                   wifi_event_handler, NULL),
        TAG, "register IP events");

    wifi_config_t config = {0};
    strlcpy((char *)config.sta.ssid, VIDEO_WIFI_SSID,
            sizeof(config.sta.ssid));
    strlcpy((char *)config.sta.password, VIDEO_WIFI_PASSWORD,
            sizeof(config.sta.password));
    config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    config.sta.pmf_cfg.capable = true;
    config.sta.pmf_cfg.required = false;
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG,
                        "set storage");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "set mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &config), TAG,
                        "set station config");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "start Wi-Fi");
    const wifi_band_mode_t band_mode = app_config->band == APP_BAND_5G
                                           ? WIFI_BAND_MODE_5G_ONLY
                                           : WIFI_BAND_MODE_2G_ONLY;
    ESP_RETURN_ON_ERROR(esp_wifi_set_band_mode(band_mode), TAG,
                        "select Wi-Fi band");
    ESP_RETURN_ON_ERROR(esp_wifi_set_ps(WIFI_PS_NONE), TAG,
                        "disable power save");
    ESP_RETURN_ON_ERROR(esp_wifi_connect(), TAG, "connect Wi-Fi");

    const EventBits_t bits = xEventGroupWaitBits(
        s_wifi_events, WIFI_CONNECTED_BIT | WIFI_FAILED_BIT, pdFALSE, pdFALSE,
        pdMS_TO_TICKS(20000));
    return (bits & WIFI_CONNECTED_BIT) != 0 ? ESP_OK : ESP_FAIL;
}

static void sender_task(void *argument)
{
    (void)argument;
    int socket_fd = -1;
    struct sockaddr_in destination = {
        .sin_family = AF_INET,
        .sin_port = htons(VIDEO_UDP_PORT),
        .sin_addr.s_addr = inet_addr(VIDEO_UDP_DESTINATION),
    };
    if (s_transport == APP_TRANSPORT_UDP) {
        socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
        if (socket_fd < 0) {
            ESP_LOGE(TAG, "socket creation failed: errno=%d", errno);
            atomic_fetch_add_explicit(&s_send_errors, 1,
                                      memory_order_relaxed);
            vTaskDelete(NULL);
            return;
        }
        int send_buffer = 256 * 1024;
        (void)setsockopt(socket_fd, SOL_SOCKET, SO_SNDBUF, &send_buffer,
                         sizeof(send_buffer));
        ESP_LOGI(TAG, "UDP stream to %s:%u", VIDEO_UDP_DESTINATION,
                 (unsigned)VIDEO_UDP_PORT);
    } else {
        ESP_LOGI(TAG, "raw 802.11 injection stream active");
    }

    const size_t batch_capacity = s_transport == APP_TRANSPORT_RAW
                                      ? RADIO_LINK_MAX_PAYLOAD
                                      : UDP_BATCH_BYTES;
    uint8_t batch[UDP_BATCH_BYTES];
    uint16_t batch_slots[UDP_BATCH_BYTES / 22U];
    uint16_t slot_index = 0;
    bool have_pending_slot = false;
    for (;;) {
        if (atomic_load_explicit(&s_paused, memory_order_relaxed)) {
            if (have_pending_slot) {
                (void)xQueueSend(s_free_slots, &slot_index, portMAX_DELAY);
                have_pending_slot = false;
            }
            while (xQueueReceive(s_ready_slots, &slot_index, 0) == pdTRUE) {
                (void)xQueueSend(s_free_slots, &slot_index, portMAX_DELAY);
            }
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }

        size_t batch_length = 4;
        uint32_t batch_records = 0;
        batch[0] = 'H';
        batch[1] = 'Z';
        batch[2] = 'U';
        batch[3] = 1;

        if (!have_pending_slot &&
            xQueueReceive(s_ready_slots, &slot_index,
                          pdMS_TO_TICKS(10)) != pdTRUE) {
            continue;
        }
        have_pending_slot = true;
        const int64_t coalesce_deadline_us =
            esp_timer_get_time() + RAW_BATCH_COALESCE_US;
        while (have_pending_slot) {
            udp_slot_t *slot = &s_slots[slot_index];
            const size_t encoded_length = 2U + slot->length;
            if (batch_length + encoded_length > batch_capacity) {
                break;
            }
            batch[batch_length] = (uint8_t)slot->length;
            batch[batch_length + 1] = (uint8_t)(slot->length >> 8);
            memcpy(batch + batch_length + 2, slot->data, slot->length);
            batch_length += encoded_length;
            batch_slots[batch_records] = slot_index;
            ++batch_records;
            have_pending_slot =
                xQueueReceive(s_ready_slots, &slot_index, 0) == pdTRUE;
            if (!have_pending_slot && s_transport == APP_TRANSPORT_RAW &&
                batch_length + 22U <= batch_capacity &&
                esp_timer_get_time() < coalesce_deadline_us) {
                // Keep collecting until the original one-millisecond batch
                // deadline. A single blocking receive wakes on the very next
                // record and used to leave most radio frames only half full.
                have_pending_slot = xQueueReceive(
                    s_ready_slots, &slot_index, pdMS_TO_TICKS(1)) == pdTRUE;
            }
        }

        for (;;) {
            esp_err_t raw_error = ESP_OK;
            ssize_t sent = -1;
            if (s_transport == APP_TRANSPORT_RAW) {
                raw_error = radio_link_send(batch, batch_length);
                if (raw_error == ESP_OK) {
                    sent = (ssize_t)batch_length;
                }
            } else {
                sent = sendto(
                    socket_fd, batch, batch_length, 0,
                    (const struct sockaddr *)&destination,
                    sizeof(destination));
            }
            if (sent == (ssize_t)batch_length) {
                atomic_fetch_add_explicit(&s_sent_records, batch_records,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit(&s_sent_bytes, (uint32_t)sent,
                                          memory_order_relaxed);
                break;
            }

            const uint32_t failures = (uint32_t)atomic_fetch_add_explicit(
                &s_send_errors, 1, memory_order_relaxed) + 1U;
            if (failures == 1U || (failures & 0xffU) == 0U) {
                if (s_transport == APP_TRANSPORT_RAW) {
                    ESP_LOGW(TAG, "raw TX wait: %s failures=%u",
                             esp_err_to_name(raw_error),
                             (unsigned)failures);
                } else {
                    ESP_LOGW(TAG, "sendto wait: errno=%d failures=%u", errno,
                             (unsigned)failures);
                }
            }
            // Keep every slot belonging to an accepted frame reserved until
            // the selected transport accepts the packet. Queue pressure then
            // rejects subsequent frames as a whole.
            vTaskDelay(pdMS_TO_TICKS(1));
        }
        for (uint32_t index = 0; index < batch_records; ++index) {
            xQueueSend(s_free_slots, &batch_slots[index], portMAX_DELAY);
        }
        // Raw TX already applies backpressure through ESP_ERR_NO_MEM. A
        // one-tick delay after every accepted frame capped a 1000 Hz build at
        // roughly 11 Mbit/s, far below the 40 FPS video payload. Keep the
        // pacing only for the socket path.
        if (s_transport != APP_TRANSPORT_RAW) {
            vTaskDelay(pdMS_TO_TICKS(1));
        }
    }
}

static void capture_task(void *argument)
{
    (void)argument;
    parlio_rx_unit_handle_t unit = NULL;
    parlio_rx_delimiter_handle_t delimiter = NULL;
    uint8_t *dma_buffers[DMA_BUFFER_COUNT] = {0};
    uint8_t record_copy[WIRE_TRANSACTION_BYTES];
    esp_err_t error = ESP_OK;

    parlio_rx_unit_config_t unit_config = {
        .trans_queue_depth = DMA_BUFFER_COUNT,
        .max_recv_size = DMA_BUFFER_BYTES,
        .dma_burst_size = 32,
        .data_width = 4,
        .clk_src = PARLIO_CLK_SRC_EXTERNAL,
        .ext_clk_freq_hz = 32U * 1000U * 1000U,
        .exp_clk_freq_hz = 32U * 1000U * 1000U,
        .clk_in_gpio_num = BOARD_PIN_PAR_CLK,
        .clk_out_gpio_num = -1,
        .valid_gpio_num = BOARD_PIN_PAR_CS,
        .flags = {.free_clk = false, .clk_gate_en = false},
    };
    for (size_t index = 0; index < PARLIO_RX_UNIT_MAX_DATA_WIDTH; ++index) {
        unit_config.data_gpio_nums[index] = -1;
    }
    unit_config.data_gpio_nums[0] = BOARD_PIN_PAR_D0;
    unit_config.data_gpio_nums[1] = BOARD_PIN_PAR_D1;
    unit_config.data_gpio_nums[2] = BOARD_PIN_PAR_D2;
    unit_config.data_gpio_nums[3] = BOARD_PIN_PAR_D3;

    const parlio_rx_level_delimiter_config_t delimiter_config = {
        .valid_sig_line_id = PARLIO_RX_UNIT_MAX_DATA_WIDTH - 1,
        .sample_edge = PARLIO_SAMPLE_EDGE_POS,
        .bit_pack_order = PARLIO_BIT_PACK_ORDER_MSB,
        .eof_data_len = WIRE_TRANSACTION_BYTES,
        .timeout_ticks = 0,
        .flags = {.active_low_en = false},
    };
    const parlio_rx_event_callbacks_t callbacks = {
        .on_receive_done = capture_done_callback,
    };
    parlio_receive_config_t receive_config = {
        .delimiter = NULL,
        .flags = {.partial_rx_en = false, .indirect_mount = false},
    };

    if ((error = parlio_new_rx_unit(&unit_config, &unit)) != ESP_OK ||
        (error = parlio_new_rx_level_delimiter(
             &delimiter_config, &delimiter)) != ESP_OK ||
        (error = parlio_rx_unit_register_event_callbacks(
             unit, &callbacks, NULL)) != ESP_OK ||
        (error = parlio_rx_unit_enable(unit, true)) != ESP_OK) {
        goto failed;
    }
    receive_config.delimiter = delimiter;
    for (size_t index = 0; index < DMA_BUFFER_COUNT; ++index) {
        dma_buffers[index] = heap_caps_aligned_alloc(
            32, DMA_BUFFER_BYTES, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
        if (dma_buffers[index] == NULL) {
            error = ESP_ERR_NO_MEM;
            goto failed;
        }
        if ((error = parlio_rx_unit_receive(
                 unit, dma_buffers[index], DMA_BUFFER_BYTES,
                 &receive_config)) != ESP_OK) {
            goto failed;
        }
    }
    if ((error = transmitter_diag_arm_capture()) != ESP_OK) {
        goto failed;
    }

    capture_event_t startup;
    if (xQueueReceive(s_capture_events, &startup,
                      pdMS_TO_TICKS(1000)) != pdTRUE) {
        error = ESP_ERR_TIMEOUT;
        goto failed;
    }
    if ((error = parlio_rx_unit_receive(
             unit, startup.data, DMA_BUFFER_BYTES, &receive_config)) != ESP_OK) {
        goto failed;
    }
    ESP_LOGI(TAG, "PARLIO live stream armed; startup bytes=%u",
             (unsigned)startup.bytes);

    bool have_frame = false;
    bool transmit_frame = false;
    uint16_t current_frame_id = 0;
    for (;;) {
        capture_event_t event;
        if (xQueueReceive(s_capture_events, &event, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        const size_t captured_bytes =
            event.bytes <= sizeof(record_copy) ? event.bytes : 0;
        if (captured_bytes != 0) {
            memcpy(record_copy, event.data, captured_bytes);
        }
        error = parlio_rx_unit_receive(
            unit, event.data, DMA_BUFFER_BYTES, &receive_config);
        if (error != ESP_OK) {
            goto failed;
        }

        const size_t record_size =
            encoded_record_size(record_copy, captured_bytes);
        uint16_t slot_index = 0;
        bool have_slot = false;
        if (record_size != 0) {
            atomic_fetch_add_explicit(&s_received_records, 1,
                                      memory_order_relaxed);
            const uint16_t frame_id =
                read_le16(record_copy + 6);
            if (!have_frame || frame_id != current_frame_id) {
                have_frame = true;
                current_frame_id = frame_id;
                transmit_frame = uxQueueMessagesWaiting(s_free_slots) >=
                                 MAX_RECORDS_PER_FRAME;
                atomic_fetch_add_explicit(
                    transmit_frame ? &s_accepted_frames : &s_dropped_frames,
                    1, memory_order_relaxed);
            }
            if (transmit_frame) {
                have_slot =
                    xQueueReceive(s_free_slots, &slot_index, 0) == pdTRUE;
                if (have_slot) {
                    memcpy(s_slots[slot_index].data, record_copy, record_size);
                    s_slots[slot_index].length = (uint16_t)record_size;
                } else {
                    atomic_fetch_add_explicit(&s_pool_drops, 1,
                                              memory_order_relaxed);
                    transmit_frame = false;
                }
            }
        } else {
            atomic_fetch_add_explicit(&s_invalid_records, 1,
                                      memory_order_relaxed);
        }

        if (!have_slot) {
            continue;
        }
        if (xQueueSend(s_ready_slots, &slot_index, 0) != pdTRUE) {
            atomic_fetch_add_explicit(&s_queue_drops, 1,
                                      memory_order_relaxed);
            xQueueSend(s_free_slots, &slot_index, portMAX_DELAY);
        }
    }

failed:
    ESP_LOGE(TAG, "capture task stopped: %s", esp_err_to_name(error));
    atomic_store_explicit(&s_started, false, memory_order_relaxed);
    vTaskDelete(NULL);
}

bool transmitter_udp_stream_configured(void)
{
    return VIDEO_WIFI_SSID[0] != '\0' && VIDEO_UDP_DESTINATION[0] != '\0';
}

esp_err_t transmitter_udp_stream_start(const app_config_t *config)
{
    if (config == NULL ||
        (config->transport == APP_TRANSPORT_UDP &&
         !transmitter_udp_stream_configured())) {
        return config == NULL ? ESP_ERR_INVALID_ARG :
                                ESP_ERR_NOT_SUPPORTED;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&s_started, &expected, true)) {
        return ESP_ERR_INVALID_STATE;
    }
    s_transport = config->transport;
    esp_err_t error = s_transport == APP_TRANSPORT_UDP
                          ? connect_wifi(config)
                          : radio_link_start(config);
    if (error != ESP_OK) {
        atomic_store(&s_started, false);
        return error;
    }
    s_capture_events = xQueueCreate(
        DMA_BUFFER_COUNT * 2, sizeof(capture_event_t));
    s_free_slots = xQueueCreate(UDP_SLOT_COUNT, sizeof(uint16_t));
    s_ready_slots = xQueueCreate(UDP_SLOT_COUNT, sizeof(uint16_t));
    s_slots = heap_caps_calloc(
        UDP_SLOT_COUNT, sizeof(*s_slots), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_capture_events == NULL || s_free_slots == NULL ||
        s_ready_slots == NULL || s_slots == NULL) {
        atomic_store(&s_started, false);
        return ESP_ERR_NO_MEM;
    }
    for (uint16_t index = 0; index < UDP_SLOT_COUNT; ++index) {
        xQueueSend(s_free_slots, &index, portMAX_DELAY);
    }
    if (xTaskCreate(sender_task, "video_sender", 6144, NULL, 8, NULL)
            != pdPASS ||
        xTaskCreate(capture_task, "video_capture", 6144, NULL, 24, NULL)
            != pdPASS) {
        atomic_store(&s_started, false);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

void transmitter_udp_stream_set_paused(bool paused)
{
    atomic_store_explicit(&s_paused, paused, memory_order_relaxed);
}

void transmitter_udp_stream_get_status(
    transmitter_udp_stream_status_t *status)
{
    if (status == NULL) {
        return;
    }
    *status = (transmitter_udp_stream_status_t) {
        .configured = s_transport == APP_TRANSPORT_RAW ||
                      transmitter_udp_stream_configured(),
        .transport = s_transport,
        .wifi_connected = atomic_load_explicit(
            &s_wifi_connected, memory_order_relaxed),
        .received_records = atomic_load_explicit(
            &s_received_records, memory_order_relaxed),
        .sent_records = atomic_load_explicit(
            &s_sent_records, memory_order_relaxed),
        .sent_bytes = atomic_load_explicit(
            &s_sent_bytes, memory_order_relaxed),
        .invalid_records = atomic_load_explicit(
            &s_invalid_records, memory_order_relaxed),
        .queue_drops = atomic_load_explicit(
            &s_queue_drops, memory_order_relaxed),
        .pool_drops = atomic_load_explicit(
            &s_pool_drops, memory_order_relaxed),
        .send_errors = atomic_load_explicit(
            &s_send_errors, memory_order_relaxed),
        .accepted_frames = atomic_load_explicit(
            &s_accepted_frames, memory_order_relaxed),
        .dropped_frames = atomic_load_explicit(
            &s_dropped_frames, memory_order_relaxed),
    };
}
