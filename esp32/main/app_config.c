#include "app_config.h"

#include <string.h>

#include "nvs.h"

#define CONFIG_NAMESPACE "link"

void app_config_defaults(app_config_t *config)
{
    *config = (app_config_t) {
        .role = APP_ROLE_SERVICE,
        .band = APP_BAND_5G,
        .channel = 36,
        .bandwidth_mhz = 20,
        .fpga_tx_path = APP_FPGA_TX_DEFAULT,
        .fpga_rx_path = APP_FPGA_RX_DEFAULT,
    };
}

static bool valid_image_path(const char *path, const char *role_dir)
{
    const size_t length = strnlen(path, APP_FPGA_PATH_MAX);
    return length > strlen(role_dir) && length < APP_FPGA_PATH_MAX &&
           strncmp(path, role_dir, strlen(role_dir)) == 0 &&
           strstr(path, "..") == NULL;
}

bool app_config_valid(const app_config_t *config)
{
    if (config->role > APP_ROLE_RECEIVER) {
        return false;
    }
    if (config->band != APP_BAND_2G && config->band != APP_BAND_5G) {
        return false;
    }
    if (config->bandwidth_mhz != 20 && config->bandwidth_mhz != 40) {
        return false;
    }
    if (!valid_image_path(config->fpga_tx_path, "/fs/fpga/tx/") ||
        !valid_image_path(config->fpga_rx_path, "/fs/fpga/rx/")) {
        return false;
    }
    if (config->band == APP_BAND_2G) {
        return config->channel >= 1 && config->channel <= 13;
    }
    const bool lower = config->channel >= 36 && config->channel <= 64 &&
                       (config->channel - 36) % 4 == 0;
    const bool middle = config->channel >= 100 && config->channel <= 144 &&
                        (config->channel - 100) % 4 == 0;
    const bool upper = config->channel >= 149 && config->channel <= 177 &&
                       (config->channel - 149) % 4 == 0;
    return lower || middle || upper;
}

esp_err_t app_config_load(app_config_t *config)
{
    app_config_defaults(config);

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(CONFIG_NAMESPACE, NVS_READONLY, &nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }

    uint8_t role = config->role;
    uint8_t band = config->band;
    uint8_t channel = config->channel;
    uint8_t bandwidth = config->bandwidth_mhz;
    (void)nvs_get_u8(nvs, "role", &role);
    (void)nvs_get_u8(nvs, "band", &band);
    (void)nvs_get_u8(nvs, "channel", &channel);
    (void)nvs_get_u8(nvs, "bandwidth", &bandwidth);
    size_t tx_path_size = sizeof(config->fpga_tx_path);
    size_t rx_path_size = sizeof(config->fpga_rx_path);
    (void)nvs_get_str(nvs, "fpga_tx", config->fpga_tx_path, &tx_path_size);
    (void)nvs_get_str(nvs, "fpga_rx", config->fpga_rx_path, &rx_path_size);
    nvs_close(nvs);

    config->role = (app_role_t)role;
    config->band = (app_band_t)band;
    config->channel = channel;
    config->bandwidth_mhz = bandwidth;
    if (!app_config_valid(config)) {
        return ESP_ERR_INVALID_STATE;
    }
    return ESP_OK;
}

esp_err_t app_config_save(const app_config_t *config)
{
    if (!app_config_valid(config)) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(CONFIG_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }
    if ((err = nvs_set_u8(nvs, "role", config->role)) == ESP_OK &&
        (err = nvs_set_u8(nvs, "band", config->band)) == ESP_OK &&
        (err = nvs_set_u8(nvs, "channel", config->channel)) == ESP_OK &&
        (err = nvs_set_u8(nvs, "bandwidth", config->bandwidth_mhz)) == ESP_OK &&
        (err = nvs_set_str(nvs, "fpga_tx", config->fpga_tx_path)) == ESP_OK &&
        (err = nvs_set_str(nvs, "fpga_rx", config->fpga_rx_path)) == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

const char *app_role_name(app_role_t role)
{
    switch (role) {
    case APP_ROLE_TRANSMITTER: return "tx";
    case APP_ROLE_RECEIVER: return "rx";
    default: return "service";
    }
}

const char *app_band_name(app_band_t band)
{
    return band == APP_BAND_2G ? "2g" : "5g";
}

const char *app_config_fpga_path(const app_config_t *config)
{
    return config->role == APP_ROLE_RECEIVER ? config->fpga_rx_path :
                                               config->fpga_tx_path;
}
