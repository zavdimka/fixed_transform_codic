#include "radio_test_video.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "radio_link.h"

#define TEST_HEADER_BYTES 16U
#define TEST_RECORD_MAX_BYTES 1024U

static const uint8_t TEST_MAGIC[8] = {
    'H', 'D', 'Z', 'R', 'X', 'T', '1', 0,
};

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static esp_err_t send_batch(const uint8_t *batch, size_t batch_length,
                            radio_test_video_result_t *result)
{
    for (unsigned copy = 0; copy < 2; ++copy) {
        for (;;) {
        const esp_err_t error = radio_link_send(batch, batch_length);
        if (error == ESP_OK) {
            ++result->packets;
            result->bytes += batch_length;
            vTaskDelay(pdMS_TO_TICKS(1));
            break;
        }
        if (error != ESP_ERR_NO_MEM &&
            error != ESP_ERR_WIFI_WOULD_BLOCK) {
            return error;
        }
        ++result->retries;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
    return ESP_OK;
}

esp_err_t radio_test_video_send(const char *path, uint32_t passes,
                                radio_test_video_result_t *result)
{
    if (path == NULL || passes == 0 || result == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    *result = (radio_test_video_result_t) {0};

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    uint8_t header[TEST_HEADER_BYTES];
    if (fread(header, 1, sizeof(header), file) != sizeof(header) ||
        memcmp(header, TEST_MAGIC, sizeof(TEST_MAGIC)) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_RESPONSE;
    }
    const uint16_t record_count = read_le16(header + 8);
    const uint16_t maximum_record_size = read_le16(header + 10);
    if (record_count == 0 || maximum_record_size < 20 ||
        maximum_record_size > TEST_RECORD_MAX_BYTES) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }

    uint8_t *record = malloc(TEST_RECORD_MAX_BYTES);
    uint8_t *batch = malloc(RADIO_LINK_MAX_PAYLOAD);
    if (record == NULL || batch == NULL) {
        free(record);
        free(batch);
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    esp_err_t error = ESP_OK;
    for (uint32_t pass = 0; pass < passes && error == ESP_OK; ++pass) {
        if (fseek(file, TEST_HEADER_BYTES, SEEK_SET) != 0) {
            error = ESP_FAIL;
            break;
        }
        size_t batch_length = 4;
        batch[0] = 'H';
        batch[1] = 'Z';
        batch[2] = 'U';
        batch[3] = 1;

        for (uint16_t index = 0; index < record_count; ++index) {
            uint8_t size_bytes[2];
            if (fread(size_bytes, 1, sizeof(size_bytes), file) !=
                sizeof(size_bytes)) {
                error = ESP_ERR_INVALID_SIZE;
                break;
            }
            const size_t record_size = read_le16(size_bytes);
            if (record_size < 20 || record_size > maximum_record_size ||
                fread(record, 1, record_size, file) != record_size) {
                error = ESP_ERR_INVALID_SIZE;
                break;
            }
            if (batch_length + 2U + record_size >
                RADIO_LINK_MAX_PAYLOAD) {
                error = send_batch(batch, batch_length, result);
                if (error != ESP_OK) {
                    break;
                }
                batch_length = 4;
                batch[0] = 'H';
                batch[1] = 'Z';
                batch[2] = 'U';
                batch[3] = 1;
            }
            batch[batch_length] = (uint8_t)record_size;
            batch[batch_length + 1] = (uint8_t)(record_size >> 8);
            memcpy(batch + batch_length + 2U, record, record_size);
            batch_length += 2U + record_size;
            ++result->records;
        }
        if (error == ESP_OK && batch_length > 4U) {
            error = send_batch(batch, batch_length, result);
        }
        if (error == ESP_OK) {
            ++result->passes;
        }
    }
    free(record);
    free(batch);
    fclose(file);
    return error;
}
