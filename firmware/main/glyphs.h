#ifndef GLYPHS_H
#define GLYPHS_H

#include <stdbool.h>
#include <stdint.h>

#include "board_info.h"

/* True when code point cp is in a range the fonts of one of the FONTSET_* bits in font_sets carry.
 * The range table lives in glyphs.c and is written by tools/gen_fonts.sh from the same list that
 * font_vi_22.c / font_vi_36.c are generated with. */
bool glyph_ok(uint32_t cp, uint32_t font_sets);

#endif /* GLYPHS_H */
