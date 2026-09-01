idf_component_register(
    SRCS
        "app_main.c"
        "app_config.c"
        "board_io.c"
        "radio_link.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES
        esp_driver_gpio
        esp_event
        esp_netif
        esp_wifi
        nvs_flash
)
