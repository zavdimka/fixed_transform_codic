#pragma once

#include <stdint.h>

#include "esp_err.h"

typedef struct {
    uint32_t passes;
    uint32_t records;
    uint32_t packets;
    uint32_t bytes;
    uint32_t retries;
} radio_test_video_result_t;

esp_err_t radio_test_video_send(const char *path, uint32_t passes,
                                radio_test_video_result_t *result);
