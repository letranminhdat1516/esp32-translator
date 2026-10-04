#include "claude_proto.h"
#include <string.h>

#define FLAG_FIRST 0x01
#define FLAG_LAST  0x02

/* Cuts at the last complete UTF-8 sequence so truncated text never ends mid-character */
static size_t utf8_safe_len(const uint8_t *s, size_t n)
{
    size_t i = n;
    while (i > 0 && (s[i - 1] & 0xC0) == 0x80) {
        i--;
    }
    if (i > 0 && (s[i - 1] & 0x80)) {
        uint8_t lead = s[i - 1];
        size_t need = (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
        if (n - (i - 1) < need) {
            return i - 1;
        }
    }
    return n;
}

bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out)
{
    if (len < 1) {
        return false;
    }
    uint8_t flags = chunk[0];
    if (flags & FLAG_FIRST) {
        rx->len = 0;
    }
    size_t n = len - 1;
    if (rx->len + n > sizeof(rx->buf)) {
        n = sizeof(rx->buf) - rx->len;
    }
    memcpy(rx->buf + rx->len, chunk + 1, n);
    rx->len += n;

    if (!(flags & FLAG_LAST) || rx->len < 5) {
        return false;
    }
    out->kind = (claude_kind_t)rx->buf[0];
    out->id = (uint32_t)rx->buf[1] | (uint32_t)rx->buf[2] << 8 | (uint32_t)rx->buf[3] << 16 | (uint32_t)rx->buf[4] << 24;
    size_t text_len = utf8_safe_len(rx->buf + 5, rx->len - 5);
    memcpy(out->text, rx->buf + 5, text_len);
    out->text[text_len] = '\0';
    rx->len = 0;
    return true;
}

void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5])
{
    out[0] = id & 0xff;
    out[1] = (id >> 8) & 0xff;
    out[2] = (id >> 16) & 0xff;
    out[3] = (id >> 24) & 0xff;
    out[4] = decision;
}
