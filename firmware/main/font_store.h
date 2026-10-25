#ifndef FONT_STORE_H
#define FONT_STORE_H

#include <stdbool.h>
#include <stdint.h>

#include "lvgl.h"

/* Script fonts (CJK, Hangul, Thai) kept in the 'fonts' flash partition as LVGL binfonts and used as fallbacks of
 * font_vi_22 / font_vi_36. Layout of the partition (written by tools/gen_fonts.sh store):
 *   "FNT1", count u32, count x { FONTSET_* bit u32, px u32, offset u32, size u32 }, font files (LE).
 * Glyph bitmaps are read from the memory-mapped flash on demand; only the glyph tables sit in RAM. */

/* Maps the partition and loads every font in it. Call once, with the display lock held (LVGL). A missing or damaged
 * partition leaves the store empty. */
void font_store_init(void);

/* Adds one binfont file that stays valid for good (a mapped partition, or a buffer the simulator read from disk):
 * `set` is one FONTSET_CJK / _HANGUL / _THAI bit, px 22 or 36. False when LVGL cannot parse it. */
bool font_store_add_buffer(uint32_t set, int px, const void *buf, uint32_t size);

/* FONTSET_* bits whose 22 and 36 px fonts both loaded: what board info reports besides the Latin sets */
uint32_t font_store_sets(void);

/* The font for text in the translator UI: font_vi_<px> with the loaded script fonts as its fallback chain.
 * px is 22 or 36. Without a store this is font_vi_<px> itself. */
const lv_font_t *font_store_font(int px);

#endif /* FONT_STORE_H */
