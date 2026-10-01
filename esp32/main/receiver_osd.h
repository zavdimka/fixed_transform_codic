#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "app_config.h"
#include "esp_err.h"

#define RECEIVER_OSD_COLUMNS 80
#define RECEIVER_OSD_ROWS 30
#define RECEIVER_OSD_STATS_ROWS 4
typedef enum {
    RECEIVER_OSD_BLACK = 0,
    RECEIVER_OSD_DARK_BLUE = 1,
    RECEIVER_OSD_DARK_GREEN = 2,
    RECEIVER_OSD_DARK_CYAN = 3,
    RECEIVER_OSD_DARK_RED = 4,
    RECEIVER_OSD_DARK_MAGENTA = 5,
    RECEIVER_OSD_BROWN = 6,
    RECEIVER_OSD_LIGHT_GRAY = 7,
    RECEIVER_OSD_DARK_GRAY = 8,
    RECEIVER_OSD_BRIGHT_BLUE = 9,
    RECEIVER_OSD_BRIGHT_GREEN = 10,
    RECEIVER_OSD_BRIGHT_CYAN = 11,
    RECEIVER_OSD_BRIGHT_RED = 12,
    RECEIVER_OSD_BRIGHT_MAGENTA = 13,
    RECEIVER_OSD_YELLOW = 14,
    RECEIVER_OSD_PROGRAMMABLE = 15,
} receiver_osd_color_t;

#define RECEIVER_OSD_ATTRIBUTE(foreground, background, opaque) \
    ((uint16_t)((foreground) | ((background) << 4) | \
                ((opaque) ? 0x100U : 0U)))

typedef struct {
    const char *text;
    uint16_t attribute;
} receiver_osd_span_t;


esp_err_t receiver_osd_start(const app_config_t *config);
bool receiver_osd_is_running(void);
esp_err_t receiver_osd_set_test_pattern(uint8_t mode);
esp_err_t receiver_osd_print_fpga_stats(void);

// Full-screen 80x30 text entry point. Rows 0..3 are periodically refreshed
// by receiver statistics; rows 4..29 are free for flight-controller OSD.
esp_err_t receiver_osd_write_line(uint8_t row, const char *text,
                                  uint16_t attribute);

// Writes adjacent independently colored text spans. Unused cells are cleared
// with a transparent background, making this suitable for video overlays.
esp_err_t receiver_osd_write_spans(uint8_t row,
                                   const receiver_osd_span_t *spans,
                                   size_t span_count);
