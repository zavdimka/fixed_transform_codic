idf_component_register(
    SRCS
        "app_main.c"
        "app_config.c"
        "board_io.c"
        "decoder_test_stream.c"
        "camera_ov5640.c"
        "filesystem.c"
        "firmware_update.c"
        "fpga_loader.c"
        "osd_font7x10.c"
        "radio_link.c"
        "receiver_osd.c"
        "transmitter_diag.c"
        "transmitter_capture.c"
        "parlio_selftest.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES
        esp_driver_gpio
        esp_driver_parlio
        esp_driver_i2c
        esp_driver_spi
        esp_driver_usb_serial_jtag
        esp_event
        esp_hw_support
        app_update
        esp_netif
        esp_wifi
        littlefs
        nvs_flash
)

littlefs_create_partition_image(storage ../fs FLASH_IN_PROJECT)
