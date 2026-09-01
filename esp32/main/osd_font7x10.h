#pragma once

#include <stdint.h>

#define OSD_FONT_WIDTH 7
#define OSD_FONT_HEIGHT 10

// Returns one seven-bit raster row of the 7x10 display glyph. Lower-case ASCII
// is intentionally mapped to upper case for a compact, readable FPV font.
uint8_t osd_font7x10_row(char character, uint8_t row);
