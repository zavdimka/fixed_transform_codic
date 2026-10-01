#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool running;
    uint32_t radio_batches;
    uint32_t radio_bytes;
    uint32_t records;
    uint32_t record_bytes;
    uint32_t invalid_batches;
    uint32_t invalid_records;
    uint32_t duplicate_records;
    uint32_t filtered_enhancement_records;
    uint32_t filtered_other_records;
    uint32_t queue_drops;
    uint32_t assembled_records;
    uint32_t completed_frames;
    uint32_t incomplete_frames;
    uint32_t replayed_frames;
    uint32_t parlio_errors;
    esp_err_t last_error;
} receiver_radio_stream_status_t;

// Reserves the internal DMA staging pool, creates the PSRAM-backed
// complete-frame assembly/replay queues and starts the PARLIO feeder.
esp_err_t receiver_radio_stream_start(void);

// Called by radio_link from the Wi-Fi driver task. It only validates batch
// framing, copies into a free PSRAM slot and returns without blocking.
void receiver_radio_stream_ingest(const uint8_t *payload,
                                  size_t payload_size,
                                  void *context);

void receiver_radio_stream_get_status(receiver_radio_stream_status_t *status);
void receiver_radio_stream_print_status(void);
