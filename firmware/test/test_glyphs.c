// firmware/test/test_glyphs.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_glyphs test_glyphs.c ../main/glyphs.c && /tmp/test_glyphs
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "board_info.h"
#include "glyphs.h"

/* The static glyph_ok the firmware had before A1 (font_vi_22/36 -r list) */
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

static void label_clip(void)
{
    char out[LABEL_MAX + 1];
    assert(label_normalize("Fran\xc3\xa7" "ais", 9, out) && !strcmp(out, "Fran\xc3\xa7" "ais"));
    assert(label_normalize("", 0, out) && out[0] == '\0');
    assert(label_normalize("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", 9, out) && strlen(out) == 9);
    /* invalid: lone continuation, truncated sequence, overlong, surrogate, > U+10FFFF */
    assert(!label_normalize("a\x80", 2, out));
    assert(!label_normalize("a\xe6\x97", 3, out));
    assert(!label_normalize("\xc0\x80", 2, out));
    assert(!label_normalize("\xed\xa0\x80", 3, out));
    assert(!label_normalize("\xf4\x90\x80\x80", 4, out));
    /* 40 bytes of 3-byte chars: cut at a character boundary <= 32 bytes (30) */
    char big[41];
    for (int i = 0; i < 13; i++) {
        memcpy(big + 3 * i, "\xe6\x97\xa5", 3);
    }
    assert(label_normalize(big, 39, out) && strlen(out) == 30);
    char ascii[40];
    memset(ascii, 'x', sizeof(ascii));
    assert(label_normalize(ascii, 40, out) && strlen(out) == 32);
}

static void cut(void)
{
    const char *s = "ab\xe6\x97\xa5\xe6\x9c\xac"; /* ab日本, 8 bytes */
    assert(utf8_cut_len(s, 8, 8) == 8);
    assert(utf8_cut_len(s, 8, 7) == 5); /* 6 and 7 would split 本 */
    assert(utf8_cut_len(s, 8, 5) == 5);
    assert(utf8_cut_len(s, 8, 4) == 2); /* would split 日 */
    assert(utf8_cut_len(s, 8, 2) == 2);
    assert(utf8_cut_len(s, 8, 0) == 0);
    assert(utf8_cut_len("abc", 3, 2) == 2);
}

int main(void)
{
    no_regression();
    canonical_ranges();
    per_set();
    label_clip();
    cut();
    puts("test_glyphs ok");
    return 0;
}
