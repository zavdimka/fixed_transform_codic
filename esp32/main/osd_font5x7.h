#pragma once

#include <stdint.h>

#define OSD_FONT_WIDTH 5
#define OSD_FONT_HEIGHT 7

// Returns five columns, least-significant bit at the top. Lower-case ASCII is
// intentionally mapped to upper case for a compact, highly readable FPV font.
const uint8_t *osd_font5x7_glyph(char character);
