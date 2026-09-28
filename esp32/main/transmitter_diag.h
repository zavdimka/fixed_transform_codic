#pragma once

#include <stdbool.h>

#include "esp_err.h"

esp_err_t transmitter_diag_start(void);
esp_err_t transmitter_diag_stop(void);
esp_err_t transmitter_diag_print_status(void);
esp_err_t transmitter_diag_arm_capture(void);
esp_err_t transmitter_diag_capture(void);
