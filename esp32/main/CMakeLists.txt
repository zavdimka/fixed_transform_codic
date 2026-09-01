idf_component_register(
    SRCS
        "app_main.c"
        "app_config.c"
        "board_io.c"
        "filesystem.c"
        "fpga_loader.c"
        "osd_font7x10.c"
        "radio_link.c"
        "receiver_osd.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES
        esp_driver_gpio
        esp_driver_spi
        esp_event
        esp_netif
        esp_wifi
        littlefs
        nvs_flash
)

littlefs_create_partition_image(storage ../fs FLASH_IN_PROJECT)
