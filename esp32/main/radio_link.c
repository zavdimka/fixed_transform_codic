#include "radio_link.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LINK_ETHERTYPE_HI 0x88
#define LINK_ETHERTYPE_LO 0xB5

typedef struct __attribute__((packed)) {
    uint16_t frame_control;
    uint16_t duration;
    uint8_t destination[6];
    uint8_t source[6];
    uint8_t bssid[6];
    uint16_t sequence;
    uint8_t protocol[2];
} raw_header_t;

static const char *TAG = "radio";
static app_role_t s_role;
static uint8_t s_source_mac[6];
static atomic_uint_fast32_t s_rx_packets;
static atomic_uint_fast32_t s_rx_bytes;
static atomic_uint_fast32_t s_rx_lost;
static atomic_int_fast32_t s_rssi_dbm = -127;
static atomic_uint_fast32_t s_tx_sequence;
static atomic_uint_fast32_t s_tx_completed;
static atomic_uint_fast32_t s_tx_failed;
static uint16_t s_last_rx_sequence;
static bool s_have_rx_sequence;

static void IRAM_ATTR raw_tx_done(const esp_80211_tx_info_t *tx_info)
{
    if (tx_info != NULL && tx_info->tx_status == WIFI_SEND_SUCCESS) {
        atomic_fetch_add_explicit(&s_tx_completed, 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&s_tx_failed, 1, memory_order_relaxed);
    }
}

static void IRAM_ATTR promiscuous_rx(void *buffer, wifi_promiscuous_pkt_type_t type)
{
    if (type != WIFI_PKT_DATA || buffer == NULL) {
        return;
    }
    const wifi_promiscuous_pkt_t *packet = buffer;
    if (packet->rx_ctrl.sig_len < sizeof(raw_header_t)) {
        return;
    }
    const raw_header_t *header = (const raw_header_t *)packet->payload;
    if (header->protocol[0] == LINK_ETHERTYPE_HI &&
        header->protocol[1] == LINK_ETHERTYPE_LO) {
        atomic_fetch_add_explicit(&s_rx_packets, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&s_rx_bytes, packet->rx_ctrl.sig_len,
                                  memory_order_relaxed);
        atomic_store_explicit(&s_rssi_dbm, packet->rx_ctrl.rssi,
                              memory_order_relaxed);

        const uint16_t sequence = (header->sequence >> 4) & 0x0fffU;
        if (s_have_rx_sequence) {
            const uint16_t distance = (sequence - s_last_rx_sequence) & 0x0fffU;
            // Ignore duplicates and large backwards/reordered jumps. Ordinary
            // forward gaps represent packets lost on this one-way link.
            if (distance > 1 && distance < 0x0800U) {
                atomic_fetch_add_explicit(&s_rx_lost, distance - 1,
                                          memory_order_relaxed);
            }
        }
        s_last_rx_sequence = sequence;
        s_have_rx_sequence = true;
    }
}

esp_err_t radio_link_start(const app_config_t *config)
{
    if (config == NULL || config->role == APP_ROLE_SERVICE) {
        return ESP_ERR_INVALID_ARG;
    }

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "esp_netif_init");
    esp_err_t err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        return err;
    }

    wifi_init_config_t wifi_init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&wifi_init), TAG, "esp_wifi_init");
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "set storage");
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "set mode");

    // MCS8/9 are opt-in in ESP-IDF 6.1. The default STA capability mask only
    // enables HE MCS0..7, so configuring a fixed MCS9 rate otherwise fails.
    wifi_config_t sta_config = {0};
    sta_config.sta.he_mcs9_enabled = 1;
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_config(WIFI_IF_STA, &sta_config), TAG,
        "enable HE MCS8/9");

    // ESP32-C5 starts in dual-band mode. Explicit per-band protocol masks are
    // required before a fixed 11a/HT/VHT/HE rate can be selected.
    wifi_protocols_t protocols = {
        .ghz_2g = WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G |
                  WIFI_PROTOCOL_11N | WIFI_PROTOCOL_11AX,
        .ghz_5g = WIFI_PROTOCOL_11A | WIFI_PROTOCOL_11N |
                  WIFI_PROTOCOL_11AC | WIFI_PROTOCOL_11AX,
    };
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_protocols(WIFI_IF_STA, &protocols), TAG,
        "set per-band protocols");

    // Prefer the fastest HE20 profile, but retain a standards-compliant 5 GHz
    // OFDM fallback so an unsupported optional MCS cannot disable raw injection.
    wifi_tx_rate_config_t tx_rates[] = {
        {
            .phymode = WIFI_PHY_MODE_HE20,
            .rate = WIFI_PHY_RATE_MCS9_SGI,
            .ersu = false,
            .dcm = false,
        },
        {
            .phymode = WIFI_PHY_MODE_HE20,
            .rate = WIFI_PHY_RATE_MCS7_SGI,
            .ersu = false,
            .dcm = false,
        },
        {
            .phymode = WIFI_PHY_MODE_11A,
            .rate = WIFI_PHY_RATE_54M,
            .ersu = false,
            .dcm = false,
        },
    };
    static const char *const tx_rate_names[] = {
        "HE20 MCS9 SGI", "HE20 MCS7 SGI", "802.11a 54M",
    };
    const char *selected_tx_rate_name = "driver automatic";
    size_t tx_rate_index = 0;
    esp_err_t tx_rate_err = ESP_FAIL;
    for (; tx_rate_index < sizeof(tx_rates) / sizeof(tx_rates[0]);
         ++tx_rate_index) {
        tx_rate_err = esp_wifi_config_80211_tx(WIFI_IF_STA,
                                               &tx_rates[tx_rate_index]);
        if (tx_rate_err == ESP_OK) {
            break;
        }
        ESP_LOGW(TAG, "raw TX rate %s rejected: %s",
                 tx_rate_names[tx_rate_index], esp_err_to_name(tx_rate_err));
    }
    if (tx_rate_err == ESP_OK) {
        selected_tx_rate_name = tx_rate_names[tx_rate_index];
    }
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "esp_wifi_start");
    ESP_RETURN_ON_ERROR(esp_wifi_set_ps(WIFI_PS_NONE), TAG, "disable power save");
    ESP_RETURN_ON_ERROR(
        esp_wifi_register_80211_tx_cb(raw_tx_done), TAG,
        "register raw TX callback");

    const wifi_band_mode_t band_mode = config->band == APP_BAND_5G
                                           ? WIFI_BAND_MODE_5G_ONLY
                                           : WIFI_BAND_MODE_2G_ONLY;
    ESP_RETURN_ON_ERROR(esp_wifi_set_band_mode(band_mode), TAG, "set band");
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_bandwidth(WIFI_IF_STA,
                               config->bandwidth_mhz == 40 ? WIFI_BW40
                                                          : WIFI_BW20),
        TAG, "set bandwidth");
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_channel(config->channel, WIFI_SECOND_CHAN_NONE),
        TAG, "set channel");

    // On ESP32-C5 IDF 6.1 the pre-start rate API sees dual-band AUTO mode and
    // may reject every 5 GHz rate. Retry after selecting the actual band.
    if (tx_rate_err != ESP_OK) {
        for (tx_rate_index = 0;
             tx_rate_index < sizeof(tx_rates) / sizeof(tx_rates[0]);
             ++tx_rate_index) {
            tx_rate_err = esp_wifi_config_80211_tx(WIFI_IF_STA,
                                                   &tx_rates[tx_rate_index]);
            if (tx_rate_err == ESP_OK) {
                selected_tx_rate_name = tx_rate_names[tx_rate_index];
                break;
            }
        }
        if (tx_rate_err != ESP_OK) {
            ESP_LOGW(TAG, "fixed raw TX rates rejected after band selection; "
                          "using driver automatic rate");
        }
    }
    ESP_RETURN_ON_ERROR(esp_read_mac(s_source_mac, ESP_MAC_WIFI_STA), TAG, "read MAC");

    s_role = config->role;
    if (s_role == APP_ROLE_RECEIVER) {
        wifi_promiscuous_filter_t filter = {
            .filter_mask = WIFI_PROMIS_FILTER_MASK_DATA,
        };
        ESP_RETURN_ON_ERROR(
            esp_wifi_set_promiscuous_filter(&filter), TAG, "RX filter");
        ESP_RETURN_ON_ERROR(
            esp_wifi_set_promiscuous_rx_cb(promiscuous_rx), TAG, "RX callback");
        ESP_RETURN_ON_ERROR(esp_wifi_set_promiscuous(true), TAG, "promiscuous mode");
    }

    ESP_LOGI(TAG, "%s %s channel %u, %u MHz, fixed %s",
             app_role_name(config->role), app_band_name(config->band),
             config->channel, config->bandwidth_mhz,
             selected_tx_rate_name);
    return ESP_OK;
}

esp_err_t radio_link_send(const void *payload, size_t payload_size)
{
    if (s_role != APP_ROLE_TRANSMITTER) {
        return ESP_ERR_INVALID_STATE;
    }
    if (payload == NULL || payload_size == 0 || payload_size > RADIO_LINK_MAX_PAYLOAD) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t frame[sizeof(raw_header_t) + RADIO_LINK_MAX_PAYLOAD];
    raw_header_t *header = (raw_header_t *)frame;
    *header = (raw_header_t) {
        .frame_control = 0x0008,
        .destination = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
        .bssid = {0x02, 0x46, 0x50, 0x56, 0x00, 0x01},
        .protocol = {LINK_ETHERTYPE_HI, LINK_ETHERTYPE_LO},
    };
    const uint16_t sequence = atomic_fetch_add_explicit(
        &s_tx_sequence, 1, memory_order_relaxed) & 0x0fffU;
    header->sequence = sequence << 4;
    memcpy(header->source, s_source_mac, sizeof(header->source));
    memcpy(frame + sizeof(*header), payload, payload_size);
    return esp_wifi_80211_tx(WIFI_IF_STA, frame,
                             sizeof(*header) + payload_size, false);
}

uint32_t radio_link_rx_packets(void)
{
    return atomic_load_explicit(&s_rx_packets, memory_order_relaxed);
}

void radio_link_get_stats(radio_link_stats_t *stats)
{
    if (stats == NULL) {
        return;
    }
    *stats = (radio_link_stats_t) {
        .rx_packets = atomic_load_explicit(&s_rx_packets, memory_order_relaxed),
        .rx_bytes = atomic_load_explicit(&s_rx_bytes, memory_order_relaxed),
        .rx_lost = atomic_load_explicit(&s_rx_lost, memory_order_relaxed),
        .rssi_dbm = (int8_t)atomic_load_explicit(&s_rssi_dbm,
                                                 memory_order_relaxed),
    };
}

esp_err_t radio_link_benchmark(size_t payload_size, uint32_t packet_count,
                               radio_link_benchmark_t *result)
{
    if (result == NULL || s_role != APP_ROLE_TRANSMITTER ||
        payload_size == 0 || payload_size > RADIO_LINK_MAX_PAYLOAD ||
        packet_count == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    uint8_t *payload = malloc(payload_size);
    if (payload == NULL) {
        return ESP_ERR_NO_MEM;
    }
    for (size_t index = 0; index < payload_size; ++index) {
        payload[index] = (uint8_t)(index ^ (index >> 8));
    }

    const uint32_t completed_before = atomic_load_explicit(
        &s_tx_completed, memory_order_relaxed);
    const uint32_t failed_before = atomic_load_explicit(
        &s_tx_failed, memory_order_relaxed);
    uint32_t accepted = 0;
    uint32_t retries = 0;
    const int64_t start_us = esp_timer_get_time();
    while (accepted < packet_count) {
        const esp_err_t error = radio_link_send(payload, payload_size);
        if (error == ESP_OK) {
            ++accepted;
        } else if (error == ESP_ERR_NO_MEM ||
                   error == ESP_ERR_WIFI_WOULD_BLOCK) {
            ++retries;
            taskYIELD();
        } else {
            free(payload);
            return error;
        }
        if ((accepted & 0xffU) == 0) {
            taskYIELD();
        }
    }

    const int64_t deadline_us = esp_timer_get_time() + 10000000;
    while ((atomic_load_explicit(&s_tx_completed, memory_order_relaxed) -
                completed_before) +
               (atomic_load_explicit(&s_tx_failed, memory_order_relaxed) -
                failed_before) < accepted &&
           esp_timer_get_time() < deadline_us) {
        vTaskDelay(1);
    }
    const int64_t end_us = esp_timer_get_time();
    free(payload);

    *result = (radio_link_benchmark_t) {
        .payload_size = payload_size,
        .requested_packets = packet_count,
        .accepted_packets = accepted,
        .api_retries = retries,
        .tx_completed = atomic_load_explicit(
                            &s_tx_completed, memory_order_relaxed) -
                        completed_before,
        .tx_failed = atomic_load_explicit(
                         &s_tx_failed, memory_order_relaxed) -
                     failed_before,
        .elapsed_us = (uint32_t)(end_us - start_us),
    };
    return result->tx_completed + result->tx_failed == accepted
               ? ESP_OK : ESP_ERR_TIMEOUT;
}