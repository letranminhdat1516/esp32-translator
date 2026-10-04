// firmware/test/test_ancs.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_ancs test_ancs.c ../main/ancs.c && /tmp/test_ancs
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "ancs.h"

/* "7905F431-B5CE-..." (big-endian text) → 16 little-endian bytes */
static void uuid_le(const char *s, uint8_t out[16])
{
    uint8_t be[16];
    int n = 0;
    for (const char *p = s; *p && n < 16; p++) {
        if (*p == '-') {
            continue;
        }
        unsigned v;
        assert(sscanf(p, "%2x", &v) == 1);
        be[n++] = (uint8_t)v;
        p++;
    }
    assert(n == 16);
    for (int i = 0; i < 16; i++) {
        out[i] = be[15 - i];
    }
}

static void uuids_match_apple(void)
{
    const uint8_t svc[16] = { ANCS_UUID_SVC }, src[16] = { ANCS_UUID_SOURCE };
    const uint8_t cp[16] = { ANCS_UUID_CONTROL }, ds[16] = { ANCS_UUID_DATA };
    uint8_t want[16];
    uuid_le("7905F431-B5CE-4E99-A40F-4B1E122D00D0", want);
    assert(memcmp(svc, want, 16) == 0);
    uuid_le("9FBF120D-6301-42D9-8C58-25E699A21DBD", want);
    assert(memcmp(src, want, 16) == 0);
    uuid_le("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9", want);
    assert(memcmp(cp, want, 16) == 0);
    uuid_le("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB", want);
    assert(memcmp(ds, want, 16) == 0);
}

static void source_parses(void)
{
    const uint8_t d[8] = { 0x00, 0x18, 0x04, 0x01, 0x2a, 0x00, 0x00, 0x00 };
    ancs_source_t ev;
    assert(ancs_parse_source(d, 8, &ev));
    assert(ev.event == ANCS_EVENT_ADDED && ev.flags == (ANCS_FLAG_POSITIVE | ANCS_FLAG_NEGATIVE));
    assert(ev.category == 4 && ev.count == 1 && ev.uid == 42);
    const uint8_t removed[8] = { 0x02, 0x04, 0x00, 0x00, 0x04, 0x03, 0x02, 0x01 };
    assert(ancs_parse_source(removed, 8, &ev) && ev.event == ANCS_EVENT_REMOVED && ev.uid == 0x01020304);
    assert(ev.flags & ANCS_FLAG_PRE_EXISTING);
    assert(!ancs_parse_source(d, 7, &ev));
    const uint8_t nine[9] = { 0 };
    assert(!ancs_parse_source(nine, 9, &ev));
    const uint8_t bad_event[8] = { 0x03, 0, 0, 0, 1, 0, 0, 0 };
    assert(!ancs_parse_source(bad_event, 8, &ev));
}

static void commands_match_apple(void)
{
    uint8_t out[ANCS_CMD_MAX];
    assert(ancs_encode_get_attrs(0x01020304, ANCS_APP_ATTRS, sizeof ANCS_APP_ATTRS, out, sizeof out) == 6);
    const uint8_t want_app[6] = { 0x00, 0x04, 0x03, 0x02, 0x01, 0x00 };
    assert(memcmp(out, want_app, 6) == 0);
    assert(ancs_encode_get_attrs(42, ANCS_DETAIL_ATTRS, sizeof ANCS_DETAIL_ATTRS, out, sizeof out) == 16);
    const uint8_t want_details[16] = { 0x00, 0x2a, 0x00, 0x00, 0x00, 0x01, 0x40, 0x00, 0x02, 0x40, 0x00,
                                       0x03, 0xf0, 0x00, 0x06, 0x07 };
    assert(memcmp(out, want_details, 16) == 0);
    assert(ancs_encode_get_attrs(42, ANCS_DETAIL_ATTRS, sizeof ANCS_DETAIL_ATTRS, out, 15) == 0);   /* too small */
    assert(ancs_encode_get_attrs(42, ANCS_DETAIL_ATTRS, 0, out, sizeof out) == 0);                  /* nothing asked */
    assert(ancs_encode_action(42, ANCS_ACTION_POSITIVE, out) == 6);
    const uint8_t want_pos[6] = { 0x02, 0x2a, 0x00, 0x00, 0x00, 0x00 };
    assert(memcmp(out, want_pos, 6) == 0);
    assert(ancs_encode_action(42, ANCS_ACTION_NEGATIVE, out) == 6 && out[5] == 0x01);
    assert(ancs_encode_action(42, 2, out) == 0);
}

/* Test reply builders: header [0][uid u32 LE], then [id][len u16 LE][value] */
static size_t reply_header(uint8_t *buf, uint32_t uid)
{
    buf[0] = 0x00;
    buf[1] = uid & 0xff;
    buf[2] = (uid >> 8) & 0xff;
    buf[3] = (uid >> 16) & 0xff;
    buf[4] = (uid >> 24) & 0xff;
    return 5;
}

static size_t put_attr(uint8_t *buf, size_t at, uint8_t id, const char *value)
{
    size_t n = strlen(value);
    buf[at] = id;
    buf[at + 1] = n & 0xff;
    buf[at + 2] = (n >> 8) & 0xff;
    memcpy(buf + at + 3, value, n);
    return at + 3 + n;
}

static size_t details_wire(uint8_t *wire, uint32_t uid)
{
    size_t n = reply_header(wire, uid);
    n = put_attr(wire, n, ANCS_ATTR_TITLE, "Claude");
    n = put_attr(wire, n, ANCS_ATTR_SUBTITLE, "");
    n = put_attr(wire, n, ANCS_ATTR_MESSAGE, "Allow Bash: npm test?");
    n = put_attr(wire, n, ANCS_ATTR_POSITIVE, "Allow");
    return put_attr(wire, n, ANCS_ATTR_NEGATIVE, "Deny");
}

static void reply_reassembles_split_chunks(void)
{
    uint8_t wire[200];
    size_t n = details_wire(wire, 42);
    for (size_t split = 1; split < n; split++) {   /* every split point, as two notifications */
        ancs_reply_t r;
        ancs_reply_start(&r, 42, 5);
        assert(ancs_reply_feed(&r, wire, split) == ANCS_REPLY_MORE);
        assert(ancs_reply_feed(&r, wire + split, n - split) == ANCS_REPLY_DONE);
        const uint8_t *v;
        uint16_t len;
        assert(ancs_reply_attr(&r, ANCS_ATTR_MESSAGE, &v, &len) && len == 21);
        assert(memcmp(v, "Allow Bash: npm test?", 21) == 0);
        assert(ancs_reply_attr(&r, ANCS_ATTR_SUBTITLE, &v, &len) && len == 0);
        assert(ancs_reply_attr(&r, ANCS_ATTR_NEGATIVE, &v, &len) && len == 4 && memcmp(v, "Deny", 4) == 0);
        assert(!ancs_reply_attr(&r, ANCS_ATTR_APP_ID, &v, &len));   /* not asked, not there */
    }
    ancs_reply_t r;   /* one byte per notification */
    ancs_reply_start(&r, 42, 5);
    for (size_t i = 0; i + 1 < n; i++) {
        assert(ancs_reply_feed(&r, wire + i, 1) == ANCS_REPLY_MORE);
    }
    assert(ancs_reply_feed(&r, wire + n - 1, 1) == ANCS_REPLY_DONE);
    ancs_reply_clear(&r);
    static const ancs_reply_t zero;
    assert(memcmp(&r, &zero, sizeof zero) == 0);
}

static void reply_rejects_bad_input(void)
{
    uint8_t wire[64];
    size_t n = reply_header(wire, 43);
    n = put_attr(wire, n, ANCS_ATTR_APP_ID, "x");
    ancs_reply_t r;
    ancs_reply_start(&r, 42, 1);
    assert(ancs_reply_feed(&r, wire, n) == ANCS_REPLY_BAD);   /* another notification's reply */
    assert(ancs_reply_feed(&r, wire, n) == ANCS_REPLY_BAD);   /* and inactive after that */
    n = reply_header(wire, 42);
    wire[0] = 0x01;                                           /* an App Attributes reply: not ours */
    n = put_attr(wire, n, ANCS_ATTR_APP_ID, "x");
    ancs_reply_start(&r, 42, 1);
    assert(ancs_reply_feed(&r, wire, n) == ANCS_REPLY_BAD);
    ancs_reply_t idle = { 0 };
    assert(ancs_reply_feed(&idle, wire, 1) == ANCS_REPLY_BAD);   /* nothing asked */
    static uint8_t huge[ANCS_REPLY_MAX + 1];
    ancs_reply_start(&r, 0, 1);
    assert(ancs_reply_feed(&r, huge, sizeof huge) == ANCS_REPLY_BAD);   /* longer than anything we ask for */
    ancs_reply_start(&r, 42, 1);
    n = reply_header(wire, 42);
    wire[n] = ANCS_ATTR_APP_ID;
    wire[n + 1] = 0xff;
    wire[n + 2] = 0xff;   /* claims 65535 bytes: waits, then overflows instead of reading past the buffer */
    assert(ancs_reply_feed(&r, wire, n + 3) == ANCS_REPLY_MORE);
    assert(ancs_reply_feed(&r, huge, ANCS_REPLY_MAX) == ANCS_REPLY_BAD);
}

static void clean(const char *in, char *out, size_t size)
{
    ancs_clean_text((const uint8_t *)in, strlen(in), out, size);
}

static void clean_text_fits_the_fonts(void)
{
    char out[64];
    clean("Claude \xF0\x9F\xA4\x96 needs\n\tyou  ", out, sizeof out);
    assert(strcmp(out, "Claude needs you") == 0);                        /* emoji gone, whitespace folded */
    clean("  Tiếng Việt · “ok” — done…", out, sizeof out);
    assert(strcmp(out, "Tiếng Việt · “ok” — done…") == 0);               /* everything the fonts carry stays */
    clean("Vi\xE1\xBB", out, sizeof out);
    assert(strcmp(out, "Vi") == 0);                                      /* cut mid-character by the iPhone */
    clean("a\xC0\x80" "b\xED\xA0\x80" "c", out, sizeof out);
    assert(strcmp(out, "abc") == 0);                                     /* overlong, surrogate */
    clean("日本 ok", out, sizeof out);
    assert(strcmp(out, "ok") == 0);                                      /* no glyphs: dropped, no leading space */
    char small[5];
    clean("ừừ", small, sizeof small);
    assert(strcmp(small, "ừ") == 0);                                     /* 3-byte characters: one fits in 4 */
    clean("", out, sizeof out);
    assert(out[0] == '\0');
    assert(ancs_clean_text((const uint8_t *)"abc", 3, out, 1) == 0 && out[0] == '\0');
}

int main(void)
{
    uuids_match_apple();
    source_parses();
    commands_match_apple();
    reply_reassembles_split_chunks();
    reply_rejects_bad_input();
    clean_text_fits_the_fonts();
    puts("ancs: all tests passed");
    return 0;
}
