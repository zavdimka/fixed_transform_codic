#pragma once

#include <stddef.h>
#include <stdint.h>

#include "app_config.h"
#include "esp_err.h"

#define RADIO_LINK_MAX_PAYLOAD 1448U

typedef struct {
    uint32_t rx_packets;
    uint32_t rx_bytes;
    uint32_t rx_lost;
    int8_t rssi_dbm;
} radio_link_stats_t;

typedef struct {
    uint32_t payload_size;
    uint32_t requested_packets;
    uint32_t accepted_packets;
    uint32_t api_retries;
    uint32_t tx_completed;
    uint32_t tx_failed;
    uint32_t elapsed_us;
} radio_link_benchmark_t;

esp_err_t radio_link_start(const app_config_t *config);
esp_err_t radio_link_send(const void *payload, size_t payload_size);
uint32_t radio_link_rx_packets(void);
void radio_link_get_stats(radio_link_stats_t *stats);
esp_err_t radio_link_benchmark(size_t payload_size, uint32_t packet_count,
                               radio_link_benchmark_t *result);
