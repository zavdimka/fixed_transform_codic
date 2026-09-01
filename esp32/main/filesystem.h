#pragma once

#include <stdbool.h>

#include "esp_err.h"

#define FILESYSTEM_BASE_PATH "/fs"

esp_err_t filesystem_mount(void);
bool filesystem_is_mounted(void);
void filesystem_print_info(void);
void filesystem_print_fpga_images(void);
