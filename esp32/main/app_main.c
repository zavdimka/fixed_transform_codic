#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_config.h"
#include "board_io.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "radio_link.h"

static const char *TAG = "app";

static void print_status(const app_config_t *config)
{
    printf("role=%s band=%s channel=%u bandwidth=%uMHz rx_packets=%lu\n",
           app_role_name(config->role), app_band_name(config->band),
           config->channel, config->bandwidth_mhz,
           (unsigned long)radio_link_rx_packets());
}

static void print_help(void)
{
    puts("Commands:");
    puts("  status");
    puts("  role service|tx|rx");
    puts("  band 2g|5g");
    puts("  channel <number>");
    puts("  bandwidth 20|40");
    puts("  save");
    puts("  reboot");
    puts("Changes take effect after save and reboot.");
}

static void console_loop(app_config_t *config)
{
    char line[96];
    print_help();
    for (;;) {
        fputs("link> ", stdout);
        fflush(stdout);
        if (fgets(line, sizeof(line), stdin) == NULL) {
            clearerr(stdin);
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        line[strcspn(line, "\r\n")] = '\0';

        if (strcmp(line, "help") == 0) {
            print_help();
        } else if (strcmp(line, "status") == 0) {
            print_status(config);
        } else if (strcmp(line, "role service") == 0) {
            config->role = APP_ROLE_SERVICE;
        } else if (strcmp(line, "role tx") == 0) {
            config->role = APP_ROLE_TRANSMITTER;
        } else if (strcmp(line, "role rx") == 0) {
            config->role = APP_ROLE_RECEIVER;
        } else if (strcmp(line, "band 2g") == 0) {
            config->band = APP_BAND_2G;
            config->channel = 1;
        } else if (strcmp(line, "band 5g") == 0) {
            config->band = APP_BAND_5G;
            config->channel = 36;
        } else if (strncmp(line, "channel ", 8) == 0) {
            config->channel = strtoul(line + 8, NULL, 10);
        } else if (strcmp(line, "bandwidth 20") == 0) {
            config->bandwidth_mhz = 20;
        } else if (strcmp(line, "bandwidth 40") == 0) {
            config->bandwidth_mhz = 40;
        } else if (strcmp(line, "save") == 0) {
            esp_err_t err = app_config_save(config);
            printf("save: %s\n", esp_err_to_name(err));
        } else if (strcmp(line, "reboot") == 0) {
            esp_restart();
        } else if (line[0] != '\0') {
            puts("Unknown command. Type help.");
        }
    }
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    app_config_t config;
    err = app_config_load(&config);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "invalid stored configuration (%s), using service defaults",
                 esp_err_to_name(err));
        app_config_defaults(&config);
    }

    ESP_ERROR_CHECK(board_io_init(config.role));
    print_status(&config);

    if (config.role != APP_ROLE_SERVICE) {
        err = radio_link_start(&config);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "radio start failed: %s; console remains available",
                     esp_err_to_name(err));
        }
    }

    console_loop(&config);
}
