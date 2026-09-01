#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "app_config.h"
#include "esp_err.h"

#define RECEIVER_OSD_COLUMNS 80
#define RECEIVER_OSD_ROWS 30
#define RECEIVER_OSD_STATS_ROWS 4

esp_err_t receiver_osd_start(const app_config_t *config);
bool receiver_osd_is_running(void);

// Generic text entry point for the future flight-controller OSD. Rows 0..3
// are periodically refreshed by receiver statistics; rows 4..29 are free.
esp_err_t receiver_osd_write_line(uint8_t row, const char *text,
                                  uint16_t attribute);
