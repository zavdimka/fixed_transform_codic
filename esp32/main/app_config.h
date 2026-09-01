#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef enum {
    APP_ROLE_SERVICE = 0,
    APP_ROLE_TRANSMITTER = 1,
    APP_ROLE_RECEIVER = 2,
} app_role_t;

typedef enum {
    APP_BAND_2G = 2,
    APP_BAND_5G = 5,
} app_band_t;

typedef struct {
    app_role_t role;
    app_band_t band;
    uint8_t channel;
    uint8_t bandwidth_mhz;
} app_config_t;

void app_config_defaults(app_config_t *config);
esp_err_t app_config_load(app_config_t *config);
esp_err_t app_config_save(const app_config_t *config);
bool app_config_valid(const app_config_t *config);
const char *app_role_name(app_role_t role);
const char *app_band_name(app_band_t band);
