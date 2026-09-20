#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

void firmware_update_print_status(void);
esp_err_t firmware_update_confirm_running(void);
esp_err_t firmware_update_receive(size_t image_size, uint32_t expected_crc32);
void firmware_update_reboot_to_rom(void) __attribute__((noreturn));