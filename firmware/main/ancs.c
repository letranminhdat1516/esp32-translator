#include "ancs.h"

#include <string.h>

const uint8_t ANCS_APP_ATTRS[1] = { ANCS_ATTR_APP_ID };
const uint8_t ANCS_DETAIL_ATTRS[5] = { ANCS_ATTR_TITLE, ANCS_ATTR_SUBTITLE, ANCS_ATTR_MESSAGE, ANCS_ATTR_POSITIVE,
                                       ANCS_ATTR_NEGATIVE };

static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

static uint32_t get_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

bool ancs_parse_source(const uint8_t *data, size_t len, ancs_source_t *out)
{
    if (len != 8 || data[0] > ANCS_EVENT_REMOVED) {
        return false;
    }
    out->event = data[0];
    out->flags = data[1];
    out->category = data[2];
    out->count = data[3];
    out->uid = get_u32(data + 4);
    return true;
}

/* Title, Subtitle and Message take a max length parameter; the other attributes do not */
static uint16_t attr_max(uint8_t id)
{
    switch (id) {
    case ANCS_ATTR_TITLE:
        return ANCS_TITLE_MAX;
    case ANCS_ATTR_SUBTITLE:
        return ANCS_SUBTITLE_MAX;
    case ANCS_ATTR_MESSAGE:
        return ANCS_MESSAGE_MAX;
    default:
        return 0;
    }
}

size_t ancs_encode_get_attrs(uint32_t uid, const uint8_t *ids, size_t n, uint8_t *out, size_t out_size)
{
    size_t len = 5;
    for (size_t i = 0; i < n; i++) {
        len += attr_max(ids[i]) ? 3 : 1;
    }
    if (n == 0 || len > out_size) {
        return 0;
    }
    out[0] = ANCS_CMD_GET_NOTIF_ATTRS;
    put_u32(out + 1, uid);
    size_t p = 5;
    for (size_t i = 0; i < n; i++) {
        uint16_t max = attr_max(ids[i]);
        out[p++] = ids[i];
        if (max) {
            out[p++] = max & 0xff;
            out[p++] = max >> 8;
        }
    }
    return p;
}

size_t ancs_encode_action(uint32_t uid, uint8_t action, uint8_t out[6])
{
    if (action > ANCS_ACTION_NEGATIVE) {
        return 0;
    }
    out[0] = ANCS_CMD_PERFORM_ACTION;
    put_u32(out + 1, uid);
    out[5] = action;
    return 6;
}

void ancs_reply_start(ancs_reply_t *r, uint32_t uid, uint8_t want)
{
    memset(r, 0, sizeof(*r));
    r->uid = uid;
    r->want = want;
    r->active = want > 0;
}

void ancs_reply_clear(ancs_reply_t *r)
{
    memset(r, 0, sizeof(*r));
}

/* Number of complete attributes in the buffer */
static int complete_attrs(const ancs_reply_t *r)
{
    size_t p = 5;
    int n = 0;
    while (p + 3 <= r->len) {
        size_t alen = (size_t)r->buf[p + 1] | (size_t)r->buf[p + 2] << 8;
        if (p + 3 + alen > r->len) {
            break;
        }
        p += 3 + alen;
        n++;
    }
    return n;
}

ancs_reply_status_t ancs_reply_feed(ancs_reply_t *r, const uint8_t *chunk, size_t len)
{
    if (!r->active) {
        return ANCS_REPLY_BAD;
    }
    if (len > sizeof(r->buf) - r->len) {
        r->active = false;
        return ANCS_REPLY_BAD;
    }
    memcpy(r->buf + r->len, chunk, len);
    r->len += len;
    if (r->len >= 5 && (r->buf[0] != ANCS_CMD_GET_NOTIF_ATTRS || get_u32(r->buf + 1) != r->uid)) {
        r->active = false;
        return ANCS_REPLY_BAD;
    }
    if (r->len < 5 || complete_attrs(r) < r->want) {
        return ANCS_REPLY_MORE;
    }
    r->active = false;
    return ANCS_REPLY_DONE;
}

bool ancs_reply_attr(const ancs_reply_t *r, uint8_t id, const uint8_t **value, uint16_t *len)
{
    size_t p = 5;
    for (int i = 0; i < r->want && p + 3 <= r->len; i++) {
        uint16_t alen = (uint16_t)(r->buf[p + 1] | r->buf[p + 2] << 8);
        if (p + 3 + alen > r->len) {
            return false;
        }
        if (r->buf[p] == id) {
            *value = r->buf + p + 3;
            *len = alen;
            return true;
        }
        p += 3 + alen;
    }
    return false;
}

/* The code points font_vi_22 / font_vi_36 carry (their -r ranges) */
static bool glyph_ok(uint32_t c)
{
    return (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) || c == 0x102 || c == 0x103 || c == 0x110 ||
           c == 0x111 || c == 0x128 || c == 0x129 || c == 0x168 || c == 0x169 || c == 0x1a0 || c == 0x1a1 ||
           c == 0x1af || c == 0x1b0 || (c >= 0x1ea0 && c <= 0x1ef9) || c == 0x2013 || c == 0x2014 ||
           (c >= 0x2018 && c <= 0x201d) || c == 0x2026;
}

/* One UTF-8 character at s[0..n): its length, or 0 when invalid (bad lead or continuation, truncated, overlong,
 * surrogate, above U+10FFFF) */
static size_t utf8_next(const uint8_t *s, size_t n, uint32_t *cp)
{
    uint8_t b = s[0];
    size_t len;
    uint32_t c, min;
    if (b < 0x80) {
        *cp = b;
        return 1;
    } else if ((b & 0xe0) == 0xc0) {
        len = 2;
        c = b & 0x1f;
        min = 0x80;
    } else if ((b & 0xf0) == 0xe0) {
        len = 3;
        c = b & 0x0f;
        min = 0x800;
    } else if ((b & 0xf8) == 0xf0) {
        len = 4;
        c = b & 0x07;
        min = 0x10000;
    } else {
        return 0;
    }
    if (len > n) {
        return 0;
    }
    for (size_t i = 1; i < len; i++) {
        if ((s[i] & 0xc0) != 0x80) {
            return 0;
        }
        c = (c << 6) | (s[i] & 0x3f);
    }
    if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) {
        return 0;
    }
    *cp = c;
    return len;
}

size_t ancs_clean_text(const uint8_t *src, size_t len, char *out, size_t out_size)
{
    if (out_size == 0) {
        return 0;
    }
    size_t o = 0;
    bool space = false;   /* a space is owed before the next kept character */
    size_t i = 0;
    while (i < len) {
        uint32_t c;
        size_t n = utf8_next(src + i, len - i, &c);
        if (n == 0) {
            i++;   /* skip one bad byte */
            continue;
        }
        const uint8_t *ch = src + i;
        i += n;
        if (c <= 0x20 || c == 0x7f || c == 0xa0 || c == 0x2028 || c == 0x2029) {
            space = o > 0;
            continue;
        }
        if (!glyph_ok(c)) {
            continue;
        }
        size_t need = n + (space ? 1 : 0);
        if (o + need > out_size - 1) {
            break;
        }
        if (space) {
            out[o++] = ' ';
        }
        memcpy(out + o, ch, n);
        o += n;
        space = false;
    }
    out[o] = '\0';
    return o;
}
