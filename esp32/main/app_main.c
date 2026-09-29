#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_config.h"
#include "board_io.h"
#include "camera_ov5640.h"
#include "decoder_test_stream.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_system.h"
#include "filesystem.h"
#include "firmware_update.h"
#include "fpga_loader.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "radio_link.h"
#include "receiver_osd.h"
#include "transmitter_diag.h"
#include "transmitter_capture.h"
#include "transmitter_udp_stream.h"
#include "parlio_selftest.h"

#define HDMI_DIAGNOSTIC_PATTERN_CYCLE 1
#define HDMI_DIAGNOSTIC_INTERVAL_MS 12000

static const char *TAG = "app";

#if HDMI_DIAGNOSTIC_PATTERN_CYCLE
static void hdmi_diagnostic_pattern_task(void *argument)
{
    (void)argument;
    uint8_t mode = 1;
    for (;;) {
        const esp_err_t err = receiver_osd_set_test_pattern(mode);
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "HDMI diagnostic source: %s",
                     mode == 0 ? "decoded frame" : "gradient bars");
        } else {
            ESP_LOGW(TAG, "HDMI diagnostic switch failed: %s",
                     esp_err_to_name(err));
        }
        vTaskDelay(pdMS_TO_TICKS(HDMI_DIAGNOSTIC_INTERVAL_MS));
        mode = mode == 0 ? 1 : 0;
    }
}
#endif

static bool s_fpga_loaded;

static void print_status(const app_config_t *config)
{
    printf("role=%s transport=%s band=%s channel=%u bandwidth=%uMHz "
           "rx_packets=%lu filesystem=%s fpga=%s\n",
           app_role_name(config->role),
           app_transport_name(config->transport),
           app_band_name(config->band), config->channel,
           config->bandwidth_mhz,
           (unsigned long)radio_link_rx_packets(),
           filesystem_is_mounted() ? "mounted" : "unavailable",
           s_fpga_loaded ? "loaded" : "not-loaded");
    printf("fpga_tx=%s\nfpga_rx=%s\n", config->fpga_tx_path,
           config->fpga_rx_path);
    firmware_update_print_status();
    if (config->role == APP_ROLE_TRANSMITTER) {
        transmitter_udp_stream_status_t udp;
        transmitter_udp_stream_get_status(&udp);
        printf("stream transport=%s wifi=%u received=%lu sent=%lu "
               "bytes=%lu invalid=%lu drops=%lu send_errors=%lu "
               "accepted_frames=%lu dropped_frames=%lu\n",
               app_transport_name(config->transport), udp.wifi_connected,
               (unsigned long)udp.received_records,
               (unsigned long)udp.sent_records,
               (unsigned long)udp.sent_bytes,
               (unsigned long)udp.invalid_records,
               (unsigned long)(udp.queue_drops + udp.pool_drops),
               (unsigned long)udp.send_errors,
               (unsigned long)udp.accepted_frames,
               (unsigned long)udp.dropped_frames);
    }
}

static void run_radio_benchmark(size_t payload_size, uint32_t packet_count)
{
    radio_link_benchmark_t benchmark = {0};
    const esp_err_t error = radio_link_benchmark(
        payload_size, packet_count, &benchmark);
    const double seconds = benchmark.elapsed_us / 1000000.0;
    const double payload_mbps = seconds > 0.0
        ? benchmark.tx_completed * benchmark.payload_size * 8.0 /
              seconds / 1000000.0
        : 0.0;
    printf("RADIO_BENCH size=%lu requested=%lu accepted=%lu "
           "completed=%lu failed=%lu retries=%lu elapsed_us=%lu "
           "payload_mbps=%.3f result=%s\n",
           (unsigned long)benchmark.payload_size,
           (unsigned long)benchmark.requested_packets,
           (unsigned long)benchmark.accepted_packets,
           (unsigned long)benchmark.tx_completed,
           (unsigned long)benchmark.tx_failed,
           (unsigned long)benchmark.api_retries,
           (unsigned long)benchmark.elapsed_us, payload_mbps,
           esp_err_to_name(error));
}

static void print_help(void)
{
    puts("Commands:");
    puts("  status");
    puts("  role service|tx|rx");
    puts("  transport udp|raw");
    puts("  band 2g|5g");
    puts("  channel <number>");
    puts("  bandwidth 20|40");
    puts("  radio bench <bytes> <packets>");
    puts("  radio sweep <packets>");
    puts("  fpga list");
    puts("  fpga tx-file /fs/fpga/tx/<image>.hex.bin");
    puts("  fpga rx-file /fs/fpga/rx/<image>.hex.bin");
    puts("  fpga load [path]");
    puts("  tx status");
    puts("  tx gap <cycles>");
    puts("  tx quality 20|24");
    puts("  tx capture selftest");
    puts("  tx capture <packet-count>");
    puts("  tx capture status");
    puts("  tx capture dump");
    puts("  stream status");
    puts("  udp status (alias)");
    puts("  camera probe");
    puts("  camera init");
    puts("  camera pattern 0|1");
    puts("  camera order 0|1|2|3");
    puts("  camera hts <1896..65535>");
    puts("  camera timing");
    puts("  camera capture");
    puts("  hdmi pattern 0|1|2|3");
    puts("  decoder play [path]");
    puts("  decoder stop");
    puts("  decoder status");
    puts("  update status");
    puts("  update receive <size> <crc32-hex>");
    puts("  save");
    puts("  reboot");
    puts("  reboot bootloader CONFIRM");
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
    bool prompt_pending = true;
    print_help();
    for (;;) {
        if (prompt_pending) {
            fputs("link> ", stdout);
            fflush(stdout);
            prompt_pending = false;
        }
        if (fgets(line, sizeof(line), stdin) == NULL) {
            clearerr(stdin);
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }
        line[strcspn(line, "\r\n")] = '\0';
        prompt_pending = true;

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
        } else if (strcmp(line, "transport udp") == 0) {
            config->transport = APP_TRANSPORT_UDP;
        } else if (strcmp(line, "transport raw") == 0) {
            config->transport = APP_TRANSPORT_RAW;
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
        } else if (strncmp(line, "radio bench ", 12) == 0) {
            unsigned long bytes = 0;
            unsigned long packets = 0;
            char extra = '\0';
            const int fields = sscanf(line + 12, "%lu %lu %c", &bytes,
                                      &packets, &extra);
            if (fields == 2 && bytes > 0 &&
                bytes <= RADIO_LINK_MAX_PAYLOAD && packets > 0) {
                run_radio_benchmark(bytes, packets);
            } else {
                puts("radio bench: ESP_ERR_INVALID_ARG");
            }
        } else if (strncmp(line, "radio sweep ", 12) == 0) {
            char *end = NULL;
            const unsigned long packets = strtoul(line + 12, &end, 10);
            static const size_t sizes[] = {128, 512, 1024, 1448};
            if (end == NULL || *end != '\0' || packets == 0) {
                puts("radio sweep: ESP_ERR_INVALID_ARG");
            } else {
                for (size_t index = 0;
                     index < sizeof(sizes) / sizeof(sizes[0]); ++index) {
                    run_radio_benchmark(sizes[index], packets);
                    vTaskDelay(pdMS_TO_TICKS(250));
                }
            }
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
            const esp_err_t load_err = receiver_osd_is_running()
                                           ? ESP_ERR_INVALID_STATE
                                           : filesystem_is_mounted()
                                           ? fpga_load_file(path)
                                           : ESP_ERR_INVALID_STATE;
            s_fpga_loaded = load_err == ESP_OK;
            printf("fpga load: %s\n", esp_err_to_name(load_err));
        } else if (strcmp(line, "tx status") == 0) {
            const esp_err_t diag_err = transmitter_diag_print_status();
            if (diag_err != ESP_OK) {
                printf("tx status: %s\n", esp_err_to_name(diag_err));
            }
        } else if (strncmp(line, "tx gap ", 7) == 0) {
            char *end = NULL;
            const unsigned long cycles = strtoul(line + 7, &end, 0);
            const bool valid =
                end != NULL && *end == '\0' && cycles > 0 &&
                cycles <= UINT16_MAX;
            const esp_err_t diag_err =
                valid ? transmitter_diag_set_gap((uint16_t)cycles)
                      : ESP_ERR_INVALID_ARG;
            printf("tx gap %lu: %s\n", cycles, esp_err_to_name(diag_err));
        } else if (strncmp(line, "tx quality ", 11) == 0) {
            char *end = NULL;
            const unsigned long quality = strtoul(line + 11, &end, 0);
            const bool valid = end != NULL && *end == '\0' &&
                               (quality == 20 || quality == 24);
            const esp_err_t diag_err =
                valid ? transmitter_diag_set_quality((uint8_t)quality)
                      : ESP_ERR_INVALID_ARG;
            printf("tx quality %lu: %s\n", quality,
                   esp_err_to_name(diag_err));
        } else if (strcmp(line, "tx capture selftest") == 0) {
            const esp_err_t stop_err = transmitter_diag_stop();
            const esp_err_t test_err = stop_err == ESP_OK
                                            ? parlio_variable_length_selftest()
                                            : stop_err;
            const esp_err_t io_err = board_io_init(config->role);
            const esp_err_t reload_err =
                io_err == ESP_OK && filesystem_is_mounted()
                    ? fpga_load_file(app_config_fpga_path(config))
                    : io_err != ESP_OK ? io_err : ESP_ERR_INVALID_STATE;
            s_fpga_loaded = reload_err == ESP_OK;
            const esp_err_t diag_err = reload_err == ESP_OK
                                           ? transmitter_diag_start()
                                           : reload_err;
            printf("tx capture selftest: %s; fpga reload: %s; diag: %s\n",
                   esp_err_to_name(test_err), esp_err_to_name(reload_err),
                   esp_err_to_name(diag_err));
        } else if (strcmp(line, "tx capture status") == 0) {
            transmitter_capture_status_t capture;
            transmitter_capture_get_status(&capture);
            printf("tx capture packets=%u bytes=%u capacity=%u "
                   "dropped=%u rotated=%u header=%u crc=%u queue=%u size=%u result=%s\n",
                   (unsigned)capture.packet_count,
                   (unsigned)capture.stored_bytes,
                   (unsigned)capture.capacity_bytes,
                   (unsigned)capture.dropped_events,
                   (unsigned)capture.rotated_records,
                   (unsigned)capture.header_errors,
                   (unsigned)capture.crc_errors,
                   (unsigned)capture.queue_overflows,
                   (unsigned)capture.size_errors,
                   esp_err_to_name(capture.last_error));
        } else if (strcmp(line, "tx capture dump") == 0) {
            const esp_err_t capture_err = transmitter_capture_dump();
            if (capture_err != ESP_OK) {
                printf("tx capture dump: %s\n",
                       esp_err_to_name(capture_err));
            }
        } else if (strncmp(line, "tx capture ", 11) == 0) {
            char *end = NULL;
            const unsigned long packets = strtoul(line + 11, &end, 10);
            const bool valid_count =
                end != NULL && *end == '\0' && packets != 0;
            const esp_err_t capture_err =
                !valid_count ? ESP_ERR_INVALID_ARG
                : config->role != APP_ROLE_TRANSMITTER
                    ? ESP_ERR_INVALID_STATE
                    : transmitter_capture_run(packets);
            printf("tx capture: %s\n", esp_err_to_name(capture_err));
        } else if (strcmp(line, "stream status") == 0 ||
                   strcmp(line, "udp status") == 0) {
            transmitter_udp_stream_status_t udp;
            transmitter_udp_stream_get_status(&udp);
            printf("stream configured=%u transport=%s wifi=%u "
                   "received=%lu sent=%lu bytes=%lu invalid=%lu "
                   "queue_drop=%lu pool_drop=%lu send_error=%lu "
                   "accepted_frames=%lu dropped_frames=%lu\n",
                   udp.configured, app_transport_name(udp.transport),
                   udp.wifi_connected,
                   (unsigned long)udp.received_records,
                   (unsigned long)udp.sent_records,
                   (unsigned long)udp.sent_bytes,
                   (unsigned long)udp.invalid_records,
                   (unsigned long)udp.queue_drops,
                   (unsigned long)udp.pool_drops,
                   (unsigned long)udp.send_errors,
                   (unsigned long)udp.accepted_frames,
                   (unsigned long)udp.dropped_frames);
        } else if (strcmp(line, "camera probe") == 0) {
            uint16_t chip_id = 0;
            const esp_err_t camera_err = camera_ov5640_probe(&chip_id);
            printf("camera probe: %s id=0x%04x\n",
                   esp_err_to_name(camera_err), chip_id);
        } else if (strcmp(line, "camera init") == 0) {
            const esp_err_t camera_err = camera_ov5640_configure_720p();
            printf("camera init: %s\n",
                   esp_err_to_name(camera_err));
        } else if (strcmp(line, "camera pattern 0") == 0 ||
                   strcmp(line, "camera pattern 1") == 0) {
            const bool enabled = line[15] == '1';
            const esp_err_t camera_err =
                camera_ov5640_set_test_pattern(enabled);
            printf("camera pattern %u: %s\n", enabled,
                   esp_err_to_name(camera_err));
        } else if (strncmp(line, "camera order ", 13) == 0 &&
                   line[13] >= '0' && line[13] <= '3' && line[14] == '\0') {
            const uint8_t order = (uint8_t)(line[13] - '0');
            const esp_err_t camera_err =
                camera_ov5640_set_yuv_order(order);
            printf("camera order %u: %s\n", order,
                   esp_err_to_name(camera_err));
        } else if (strncmp(line, "camera hts ", 11) == 0) {
            char *end = NULL;
            const unsigned long hts = strtoul(line + 11, &end, 0);
            const bool valid =
                end != NULL && *end == '\0' && hts >= 1896 && hts <= UINT16_MAX;
            const esp_err_t camera_err =
                valid ? camera_ov5640_set_hts((uint16_t)hts)
                      : ESP_ERR_INVALID_ARG;
            printf("camera hts %lu: %s\n", hts,
                   esp_err_to_name(camera_err));
        } else if (strcmp(line, "camera timing") == 0) {
            static const uint16_t addresses[] = {
                0x380c, 0x380d, 0x380e, 0x380f,
                0x3500, 0x3501, 0x3502, 0x350a, 0x350b,
                0x3503, 0x3a00,
            };
            uint8_t values[sizeof(addresses) / sizeof(addresses[0])] = {0};
            esp_err_t camera_err = ESP_OK;
            for (size_t index = 0;
                 index < sizeof(addresses) / sizeof(addresses[0]); ++index) {
                camera_err = camera_ov5640_read_register(
                    addresses[index], &values[index]);
                if (camera_err != ESP_OK) {
                    break;
                }
            }
            const unsigned hts = ((unsigned)values[0] << 8) | values[1];
            const unsigned vts = ((unsigned)values[2] << 8) | values[3];
            const unsigned exposure_q4 =
                ((unsigned)(values[4] & 0x0f) << 16) |
                ((unsigned)values[5] << 8) | values[6];
            const unsigned gain_q4 =
                ((unsigned)(values[7] & 0x03) << 8) | values[8];
            printf("camera timing: %s hts=%u vts=%u exposure_q4=%u "
                   "gain_q4=%u manual=0x%02x aec=0x%02x\n",
                   esp_err_to_name(camera_err), hts, vts, exposure_q4,
                   gain_q4, values[9], values[10]);
        } else if (strcmp(line, "camera capture") == 0) {
            const esp_err_t capture_err = transmitter_diag_capture();
            if (capture_err != ESP_OK) {
                printf("camera capture: %s\n",
                       esp_err_to_name(capture_err));
            }
        } else if (strncmp(line, "hdmi pattern ", 13) == 0) {
            char *end = NULL;
            const unsigned long mode = strtoul(line + 13, &end, 10);
            const esp_err_t pattern_err = end != NULL && *end == '\0' && mode <= 3
                                              ? receiver_osd_set_test_pattern(mode)
                                              : ESP_ERR_INVALID_ARG;
            printf("hdmi pattern: %s\n", esp_err_to_name(pattern_err));
        } else if (strcmp(line, "decoder play") == 0 ||
                   strncmp(line, "decoder play ", 13) == 0) {
            const char *path = line[12] == ' ' ? line + 13
                                                : DECODER_TEST_DEFAULT_PATH;
            esp_err_t decoder_err = receiver_osd_set_test_pattern(0);
            if (decoder_err == ESP_OK) {
                decoder_err = decoder_test_stream_start(path, true);
            }
            printf("decoder play: %s\n", esp_err_to_name(decoder_err));
        } else if (strcmp(line, "decoder stop") == 0) {
            const esp_err_t decoder_err = decoder_test_stream_stop();
            printf("decoder stop: %s\n", esp_err_to_name(decoder_err));
        } else if (strcmp(line, "decoder status") == 0) {
            decoder_test_stream_status_t decoder;
            decoder_test_stream_get_status(&decoder);
            printf("decoder file running=%u loop=%u passes=%lu records=%lu "
                   "bytes=%lu result=%s\n",
                   decoder.running, decoder.loop, (unsigned long)decoder.passes,
                   (unsigned long)decoder.records_sent,
                   (unsigned long)decoder.bytes_sent,
                   esp_err_to_name(decoder.last_error));
            const esp_err_t stats_err = receiver_osd_print_fpga_stats();
            if (stats_err != ESP_OK) {
                printf("decoder FPGA status: %s\n", esp_err_to_name(stats_err));
            }
        } else if (strcmp(line, "update status") == 0) {
            firmware_update_print_status();
        } else if (strncmp(line, "update receive ", 15) == 0) {
            unsigned long image_size = 0;
            unsigned long expected_crc = 0;
            char extra = '\0';
            const int fields = sscanf(line + 15, "%lu %lx %c", &image_size,
                                      &expected_crc, &extra);
            const esp_err_t update_err = fields == 2
                                             ? firmware_update_receive(
                                                   image_size, expected_crc)
                                             : ESP_ERR_INVALID_ARG;
            printf("update: %s\n", esp_err_to_name(update_err));
        } else if (strcmp(line, "save") == 0) {
            esp_err_t err = app_config_save(config);
            printf("save: %s\n", esp_err_to_name(err));
        } else if (strcmp(line, "reboot bootloader CONFIRM") == 0) {
            firmware_update_reboot_to_rom();
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
    err = firmware_update_confirm_running();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "could not confirm running OTA image: %s",
                 esp_err_to_name(err));
    }
    if (config.role != APP_ROLE_SERVICE && filesystem_is_mounted()) {
        err = fpga_load_file(app_config_fpga_path(&config));
        s_fpga_loaded = err == ESP_OK;
    }
    print_status(&config);

    if (config.role != APP_ROLE_SERVICE && s_fpga_loaded) {
        if (config.role == APP_ROLE_TRANSMITTER) {
            err = transmitter_diag_start();
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "transmitter diagnostics failed: %s",
                         esp_err_to_name(err));
            }
            err = camera_ov5640_configure_720p();
            if (err == ESP_OK) {
                ESP_LOGI(TAG, "OV5640 initialized for 1280x720 YUV422");
            } else {
                ESP_LOGW(TAG, "OV5640 initialization failed: %s",
                         esp_err_to_name(err));
            }
            if (err == ESP_OK) {
                err = transmitter_udp_stream_start(&config);
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "%s video start failed: %s",
                             app_transport_name(config.transport),
                             esp_err_to_name(err));
                }
            }
        }
        if (config.role == APP_ROLE_RECEIVER) {
            err = radio_link_start(&config);
            if (err != ESP_OK) {
                ESP_LOGE(TAG,
                         "radio start failed: %s; console remains available",
                         esp_err_to_name(err));
            }
            err = receiver_osd_start(&config);
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "receiver OSD start failed: %s",
                         esp_err_to_name(err));
            } else {
                err = receiver_osd_set_test_pattern(0);
                if (err == ESP_OK) {
                    err = decoder_test_stream_start(
                        DECODER_TEST_DEFAULT_PATH, true);
                }
                if (err == ESP_OK) {
                    ESP_LOGI(TAG, "decoder test stream active");
#if HDMI_DIAGNOSTIC_PATTERN_CYCLE
                    if (xTaskCreate(hdmi_diagnostic_pattern_task,
                                    "hdmi_diag", 3072, NULL, 4, NULL)
                        != pdPASS) {
                        ESP_LOGW(TAG,
                                 "could not start HDMI diagnostic cycle");
                    }
#endif
                } else {
                    ESP_LOGW(TAG, "decoder test startup failed: %s; using bars",
                             esp_err_to_name(err));
                    (void)receiver_osd_set_test_pattern(1);
                }
            }
        }
    } else if (config.role != APP_ROLE_SERVICE) {
        ESP_LOGE(TAG, "radio not started because FPGA configuration failed");
    }

    console_loop(&config);
}
