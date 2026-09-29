#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool configured;
    bool wifi_connected;
    uint32_t received_records;
    uint32_t sent_records;
    uint32_t sent_bytes;
    uint32_t invalid_records;
    uint32_t queue_drops;
    uint32_t pool_drops;
    uint32_t send_errors;
    uint32_t accepted_frames;
    uint32_t dropped_frames;
} transmitter_udp_stream_status_t;

bool transmitter_udp_stream_configured(void);
esp_err_t transmitter_udp_stream_start(void);
void transmitter_udp_stream_get_status(
    transmitter_udp_stream_status_t *status);
