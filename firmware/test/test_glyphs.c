// firmware/test/test_glyphs.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_glyphs test_glyphs.c ../main/glyphs.c && /tmp/test_glyphs
#include <assert.h>
#include <stdio.h>
#include "board_info.h"
#include "glyphs.h"

/* The static glyph_ok ancs.c had before A1 (font_vi_22/36 -r list) */
static bool old_glyph_ok(uint32_t c)
{
    return (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) || c == 0x102 || c == 0x103 || c == 0x110 ||
           c == 0x111 || c == 0x128 || c == 0x129 || c == 0x168 || c == 0x169 || c == 0x1a0 || c == 0x1a1 ||
           c == 0x1af || c == 0x1b0 || (c >= 0x1ea0 && c <= 0x1ef9) || c == 0x2013 || c == 0x2014 ||
           (c >= 0x2018 && c <= 0x201d) || c == 0x2026;
}

#define BOTH (FONTSET_LATIN_VI | FONTSET_LATIN_EXT_A)

static void no_regression(void)
{
    for (uint32_t c = 0; c < 0x110000; c++) {
        if (old_glyph_ok(c)) {
            assert(glyph_ok(c, BOTH));
        }
    }
}

static void canonical_ranges(void)
{
    static const uint32_t in[][2] = { { 0x20, 0x7e },     { 0xa0, 0xff },     { 0x100, 0x17f },
                                      { 0x1a0, 0x1a1 },   { 0x1af, 0x1b0 },   { 0x1ea0, 0x1ef9 },
                                      { 0x2013, 0x2014 }, { 0x2018, 0x201d }, { 0x2026, 0x2026 } };
    for (uint32_t c = 0; c < 0x110000; c++) {
        bool want = false;
        for (unsigned i = 0; i < sizeof(in) / sizeof(in[0]); i++) {
            want = want || (c >= in[i][0] && c <= in[i][1]);
        }
        assert(glyph_ok(c, BOTH) == want);
    }
}

static void per_set(void)
{
    assert(glyph_ok(0x141, FONTSET_LATIN_EXT_A)); /* Ł */
    assert(!glyph_ok(0x141, FONTSET_LATIN_VI));
    assert(glyph_ok(0x1ea1, FONTSET_LATIN_VI)); /* ạ */
    assert(!glyph_ok(0x1ea1, FONTSET_LATIN_EXT_A));
    assert(glyph_ok('a', FONTSET_LATIN_VI));
    assert(glyph_ok(0x102, FONTSET_LATIN_VI)); /* Ă stays in the VI set */
    assert(!glyph_ok('a', 0));
    assert(!glyph_ok(0x65e5, BOTH)); /* 日 */
    assert(!glyph_ok(0x7f, BOTH));
}

int main(void)
{
    no_regression();
    canonical_ranges();
    per_set();
    puts("test_glyphs ok");
    return 0;
}
