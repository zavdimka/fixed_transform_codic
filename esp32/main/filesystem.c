#include "filesystem.h"

#include <dirent.h>
#include <stdio.h>
#include <sys/stat.h>

#include "esp_littlefs.h"
#include "esp_log.h"

static const char *TAG = "filesystem";
static bool s_mounted;

esp_err_t filesystem_mount(void)
{
    const esp_vfs_littlefs_conf_t config = {
        .base_path = FILESYSTEM_BASE_PATH,
        .partition_label = "storage",
        .format_if_mount_failed = false,
        .dont_mount = false,
    };
    const esp_err_t err = esp_vfs_littlefs_register(&config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "LittleFS mount failed: %s", esp_err_to_name(err));
        return err;
    }
    s_mounted = true;
    filesystem_print_info();
    return ESP_OK;
}

bool filesystem_is_mounted(void)
{
    return s_mounted;
}

void filesystem_print_info(void)
{
    if (!s_mounted) {
        puts("LittleFS: not mounted");
        return;
    }

    size_t total = 0;
    size_t used = 0;
    const esp_err_t err = esp_littlefs_info("storage", &total, &used);
    if (err == ESP_OK) {
        printf("LittleFS: %u/%u bytes used\n", (unsigned)used, (unsigned)total);
    } else {
        printf("LittleFS info: %s\n", esp_err_to_name(err));
    }
}

static void print_directory(const char *path)
{
    DIR *directory = opendir(path);
    if (directory == NULL) {
        printf("  %s: unavailable\n", path);
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }
        char full_path[160];
        const int length = snprintf(full_path, sizeof(full_path), "%s/%s",
                                    path, entry->d_name);
        if (length <= 0 || (size_t)length >= sizeof(full_path)) {
            continue;
        }
        struct stat status;
        if (stat(full_path, &status) == 0 && S_ISREG(status.st_mode)) {
            printf("  %s (%lu bytes)\n", full_path, (unsigned long)status.st_size);
        }
    }
    closedir(directory);
}

void filesystem_print_fpga_images(void)
{
    if (!s_mounted) {
        puts("LittleFS is not mounted.");
        return;
    }
    puts("FPGA images:");
    print_directory(FILESYSTEM_BASE_PATH "/fpga/tx");
    print_directory(FILESYSTEM_BASE_PATH "/fpga/rx");
}
