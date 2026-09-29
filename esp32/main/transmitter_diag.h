#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t transmitter_diag_start(void);
esp_err_t transmitter_diag_stop(void);
esp_err_t transmitter_diag_print_status(void);
esp_err_t transmitter_diag_set_gap(uint16_t cycles);
esp_err_t transmitter_diag_set_quality(uint8_t quality);
esp_err_t transmitter_diag_arm_capture(void);
esp_err_t transmitter_diag_capture(void);
