#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t camera_ov5640_start(void);
esp_err_t camera_ov5640_probe(uint16_t *chip_id);
esp_err_t camera_ov5640_configure_720p(void);
esp_err_t camera_ov5640_read_register(uint16_t address, uint8_t *value);
esp_err_t camera_ov5640_set_test_pattern(bool enabled);
esp_err_t camera_ov5640_set_yuv_order(uint8_t order);
