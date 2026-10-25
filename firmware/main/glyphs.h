#ifndef GLYPHS_H
#define GLYPHS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "board_info.h"

/* True when code point cp is in a range the fonts of one of the FONTSET_* bits in font_sets carry.
 * The range table lives in glyphs.c and is written by tools/gen_fonts.sh from the same list that
 * font_vi_22.c / font_vi_36.c are generated with. */
bool glyph_ok(uint32_t cp, uint32_t font_sets);

/* Language label (text kind 3): at most LABEL_MAX bytes of UTF-8 */
#define LABEL_MAX 32

/* Copies the UTF-8 label in[0..n) to out (LABEL_MAX + 1 bytes, NUL-terminated), cut at a character boundary
 * to LABEL_MAX bytes. Returns false, out untouched, when the input is not valid UTF-8 (bad lead or continuation,
 * truncated, overlong, surrogate, above U+10FFFF). */
bool label_normalize(const char *in, size_t n, char *out);

#endif /* GLYPHS_H */
