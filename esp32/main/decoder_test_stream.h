#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#define DECODER_TEST_DEFAULT_PATH "/fs/test/decoder_enhancement.rxt"

typedef struct {
    bool running;
    bool loop;
    uint32_t passes;
    uint32_t records_sent;
    uint32_t bytes_sent;
    esp_err_t last_error;
} decoder_test_stream_status_t;

esp_err_t decoder_test_stream_start(const char *path, bool loop);
esp_err_t decoder_test_stream_stop(void);
void decoder_test_stream_get_status(decoder_test_stream_status_t *status);
