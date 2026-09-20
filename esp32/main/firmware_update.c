#include "firmware_update.h"

#include <errno.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "driver/usb_serial_jtag_vfs.h"
#include "esp_app_format.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "soc/lp_aon_reg.h"
#include "soc/soc.h"

#define OTA_CHUNK_SIZE 1024

static const char *TAG = "firmware_update";

static uint32_t crc32_update(uint32_t crc, const uint8_t *data, size_t size)
{
    while (size-- != 0) {
        crc ^= *data++;
        for (unsigned bit = 0; bit < 8; ++bit) {
            const uint32_t mask = 0U - (crc & 1U);
            crc = (crc >> 1) ^ (UINT32_C(0xEDB88320) & mask);
        }
    }
    return crc;
}

static const char *partition_label(const esp_partition_t *partition)
{
    return partition == NULL ? "none" : partition->label;
}

void firmware_update_print_status(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    const esp_partition_t *boot = esp_ota_get_boot_partition();
    const esp_partition_t *next = esp_ota_get_next_update_partition(NULL);
    printf("ota running=%s boot=%s next=%s\n", partition_label(running),
           partition_label(boot), partition_label(next));
}

esp_err_t firmware_update_confirm_running(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    if (running == NULL) {
        return ESP_ERR_NOT_FOUND;
    }

    esp_ota_img_states_t state;
    esp_err_t err = esp_ota_get_state_partition(running, &state);
    if (err == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        err = esp_ota_mark_app_valid_cancel_rollback();
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "confirmed OTA image in %s", running->label);
        }
        return err;
    }
    return err == ESP_ERR_NOT_SUPPORTED ? ESP_OK : err;
}

esp_err_t firmware_update_receive(size_t image_size, uint32_t expected_crc32)
{
    const esp_partition_t *target = esp_ota_get_next_update_partition(NULL);
    if (target == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    if (image_size < sizeof(esp_image_header_t) || image_size > target->size) {
        return ESP_ERR_INVALID_SIZE;
    }

    esp_ota_handle_t handle = 0;
    esp_err_t err = esp_ota_begin(target, image_size, &handle);
    if (err != ESP_OK) {
        return err;
    }

    // The normal console maps CR to LF. OTA payloads must be byte-exact.
    usb_serial_jtag_vfs_set_rx_line_endings(ESP_LINE_ENDINGS_LF);

    uint8_t buffer[OTA_CHUNK_SIZE] __attribute__((aligned(4)));
    size_t offset = 0;
    uint32_t crc = UINT32_C(0xFFFFFFFF);
    printf("OTA READY partition=%s size=%lu chunk=%u\n", target->label,
           (unsigned long)image_size, OTA_CHUNK_SIZE);
    fflush(stdout);

    while (offset < image_size) {
        const size_t requested = image_size - offset < sizeof(buffer)
                                     ? image_size - offset
                                     : sizeof(buffer);
        printf("OTA SEND offset=%lu size=%lu\n", (unsigned long)offset,
               (unsigned long)requested);
        fflush(stdout);

        size_t received = 0;
        while (received < requested) {
            errno = 0;
            const size_t count = fread(buffer + received, 1,
                                       requested - received, stdin);
            if (count == 0) {
                const int read_errno = errno;
                clearerr(stdin);
                if (read_errno != 0 && read_errno != EAGAIN &&
                    read_errno != EWOULDBLOCK) {
                    ESP_LOGE(TAG, "console read failed: errno=%d", read_errno);
                    err = ESP_FAIL;
                    goto abort_update;
                }
                vTaskDelay(pdMS_TO_TICKS(1));
                continue;
            }
            received += count;
        }

        crc = crc32_update(crc, buffer, requested);
        err = esp_ota_write(handle, buffer, requested);
        if (err != ESP_OK) {
            uint8_t flash_data[16];
            ESP_LOGE(TAG, "write failed at %lu: source=%p first=%02x %02x %02x %02x",
                     (unsigned long)offset, buffer, buffer[0], buffer[1],
                     buffer[2], buffer[3]);
            if (esp_partition_read(target, offset, flash_data,
                                   sizeof(flash_data)) == ESP_OK) {
                ESP_LOG_BUFFER_HEX_LEVEL(TAG, flash_data, sizeof(flash_data),
                                         ESP_LOG_ERROR);
            }
            goto abort_update;
        }
        offset += requested;
    }

    crc ^= UINT32_C(0xFFFFFFFF);
    if (crc != expected_crc32) {
        ESP_LOGE(TAG, "CRC mismatch: received=%08lx expected=%08lx",
                 (unsigned long)crc, (unsigned long)expected_crc32);
        err = ESP_ERR_INVALID_CRC;
        goto abort_update;
    }

    err = esp_ota_end(handle);
    handle = 0;
    if (err == ESP_OK) {
        err = esp_ota_set_boot_partition(target);
    }
    if (err == ESP_OK) {
        printf("OTA COMPLETE partition=%s crc32=%08lx; use reboot\n",
               target->label, (unsigned long)crc);
    }
    usb_serial_jtag_vfs_set_rx_line_endings(ESP_LINE_ENDINGS_CR);
    return err;

abort_update:
    if (handle != 0) {
        esp_ota_abort(handle);
    }
    usb_serial_jtag_vfs_set_rx_line_endings(ESP_LINE_ENDINGS_CR);
    printf("OTA FAILED offset=%lu error=%s\n", (unsigned long)offset,
           esp_err_to_name(err));
    return err;
}

void firmware_update_reboot_to_rom(void)
{
    puts("Rebooting into ESP32-C5 ROM UART/USB downloader...");
    fflush(stdout);

    // LP_AON_FORCE_DOWNLOAD_BOOT=01 selects download boot0 (UART/USB) on C5.
    REG_SET_FIELD(LP_AON_SYS_CFG_REG, LP_AON_FORCE_DOWNLOAD_BOOT, 1);
    esp_restart();
    __builtin_unreachable();
}