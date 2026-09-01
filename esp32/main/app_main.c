#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_config.h"
#include "board_io.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_system.h"
#include "filesystem.h"
#include "fpga_loader.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "radio_link.h"

static const char *TAG = "app";
static bool s_fpga_loaded;

static void print_status(const app_config_t *config)
{
    printf("role=%s band=%s channel=%u bandwidth=%uMHz rx_packets=%lu "
           "filesystem=%s fpga=%s\n",
           app_role_name(config->role), app_band_name(config->band),
           config->channel, config->bandwidth_mhz,
           (unsigned long)radio_link_rx_packets(),
           filesystem_is_mounted() ? "mounted" : "unavailable",
           s_fpga_loaded ? "loaded" : "not-loaded");
    printf("fpga_tx=%s\nfpga_rx=%s\n", config->fpga_tx_path,
           config->fpga_rx_path);
}

static void print_help(void)
{
    puts("Commands:");
    puts("  status");
    puts("  role service|tx|rx");
    puts("  band 2g|5g");
    puts("  channel <number>");
    puts("  bandwidth 20|40");
    puts("  fpga list");
    puts("  fpga tx-file /fs/fpga/tx/<image>.hex.bin");
    puts("  fpga rx-file /fs/fpga/rx/<image>.hex.bin");
    puts("  fpga load [path]");
    puts("  save");
    puts("  reboot");
    puts("Changes take effect after save and reboot.");
}

static bool set_fpga_path(char *destination, const char *required_prefix,
                          const char *path)
{
    const size_t prefix_length = strlen(required_prefix);
    const size_t path_length = strlen(path);
    if (path_length <= prefix_length || path_length >= APP_FPGA_PATH_MAX ||
        strncmp(path, required_prefix, prefix_length) != 0 ||
        strstr(path, "..") != NULL) {
        return false;
    }
    memcpy(destination, path, path_length + 1);
    return true;
}

static void console_loop(app_config_t *config)
{
    char line[192];
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
        } else if (strcmp(line, "fpga list") == 0) {
            filesystem_print_fpga_images();
        } else if (strncmp(line, "fpga tx-file ", 13) == 0) {
            puts(set_fpga_path(config->fpga_tx_path, "/fs/fpga/tx/", line + 13)
                     ? "TX image selected; use save and reboot."
                     : "Invalid TX image path.");
        } else if (strncmp(line, "fpga rx-file ", 13) == 0) {
            puts(set_fpga_path(config->fpga_rx_path, "/fs/fpga/rx/", line + 13)
                     ? "RX image selected; use save and reboot."
                     : "Invalid RX image path.");
        } else if (strcmp(line, "fpga load") == 0 ||
                   strncmp(line, "fpga load ", 10) == 0) {
            const char *path = line[9] == ' ' ? line + 10 :
                                                  app_config_fpga_path(config);
            const esp_err_t load_err = filesystem_is_mounted()
                                           ? fpga_load_file(path)
                                           : ESP_ERR_INVALID_STATE;
            s_fpga_loaded = load_err == ESP_OK;
            printf("fpga load: %s\n", esp_err_to_name(load_err));
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

    err = filesystem_mount();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "filesystem unavailable; FPGA loading disabled");
    }

    ESP_ERROR_CHECK(board_io_init(config.role));
    if (config.role != APP_ROLE_SERVICE && filesystem_is_mounted()) {
        err = fpga_load_file(app_config_fpga_path(&config));
        s_fpga_loaded = err == ESP_OK;
    }
    print_status(&config);

    if (config.role != APP_ROLE_SERVICE && s_fpga_loaded) {
        err = radio_link_start(&config);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "radio start failed: %s; console remains available",
                     esp_err_to_name(err));
        }
    } else if (config.role != APP_ROLE_SERVICE) {
        ESP_LOGE(TAG, "radio not started because FPGA configuration failed");
    }

    console_loop(&config);
}
