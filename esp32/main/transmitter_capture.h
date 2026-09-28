#pragma once

#include <stddef.h>

#include "esp_err.h"

typedef struct {
    size_t packet_count;
    size_t stored_bytes;
    size_t capacity_bytes;
    size_t dropped_events;
    size_t header_errors;
    size_t crc_errors;
    size_t queue_overflows;
    size_t size_errors;
    size_t rotated_records;
    esp_err_t last_error;
} transmitter_capture_status_t;

esp_err_t transmitter_capture_run(size_t packet_limit);
esp_err_t transmitter_capture_dump(void);
void transmitter_capture_get_status(transmitter_capture_status_t *status);
