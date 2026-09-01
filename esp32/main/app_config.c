#include "app_config.h"

#include "nvs.h"

#define CONFIG_NAMESPACE "link"

void app_config_defaults(app_config_t *config)
{
    *config = (app_config_t) {
        .role = APP_ROLE_SERVICE,
        .band = APP_BAND_5G,
        .channel = 36,
        .bandwidth_mhz = 20,
    };
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
    nvs_close(nvs);

    app_config_t loaded = {
        .role = (app_role_t)role,
        .band = (app_band_t)band,
        .channel = channel,
        .bandwidth_mhz = bandwidth,
    };
    if (!app_config_valid(&loaded)) {
        return ESP_ERR_INVALID_STATE;
    }
    *config = loaded;
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
        (err = nvs_set_u8(nvs, "bandwidth", config->bandwidth_mhz)) == ESP_OK) {
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
