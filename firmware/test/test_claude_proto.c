// firmware/test/test_claude_proto.c — build: cc -I../main -o /tmp/t test_claude_proto.c ../main/claude_proto.c && /tmp/t
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "claude_proto.h"

static void single_chunk_permission(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t c[] = { 0x03, 0, 0x04, 0x03, 0x02, 0x01, 'p', '\n', 'B', 'a', 's', 'h', '\n', 'l', 's' };
    assert(claude_rx_feed(&rx, c, sizeof c, &m));
    assert(m.kind == CLAUDE_PERMISSION && m.id == 0x01020304);
    assert(strcmp(m.text, "p\nBash\nls") == 0);
}

static void chunked_utf8_roundtrip(void)
{
    const char *text = "dự án\nBash\nrm -rf thư mục cũ";
    uint8_t msg[128] = { 0, 7, 0, 0, 0 };
    size_t n = 5 + strlen(text);
    memcpy(msg + 5, text, strlen(text));
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    bool done = false;
    for (size_t off = 0; off < n; off += 6) {
        uint8_t chunk[7];
        size_t len = n - off < 6 ? n - off : 6;
        chunk[0] = (off == 0 ? 1 : 0) | (off + len == n ? 2 : 0);
        memcpy(chunk + 1, msg + off, len);
        done = claude_rx_feed(&rx, chunk, len + 1, &m);
        assert(done == (off + len == n));
    }
    assert(m.id == 7 && strcmp(m.text, text) == 0);
}

static void first_chunk_resets_partial(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t stale[] = { 0x01, 0, 1, 0, 0, 0, 'x', 'x' };
    assert(!claude_rx_feed(&rx, stale, sizeof stale, &m));
    uint8_t fresh[] = { 0x03, 2, 9, 0, 0, 0 };
    assert(claude_rx_feed(&rx, fresh, sizeof fresh, &m));
    assert(m.kind == CLAUDE_CANCEL && m.id == 9 && m.text[0] == 0);
}

static void cancel_clears_pending(void)
{
    /* cancel parses with empty text; the UI test in Task 5 checks it clears the shown request */
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t c[] = { 0x03, 2, 0x10, 0, 0, 0 };
    assert(claude_rx_feed(&rx, c, sizeof c, &m) && m.kind == CLAUDE_CANCEL && m.id == 0x10);
}

static void overflow_is_truncated_not_crashing(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t head[] = { 0x01, 0, 1, 0, 0, 0 };
    claude_rx_feed(&rx, head, sizeof head, &m);
    uint8_t big[201];
    memset(big, 'a', sizeof big);
    big[0] = 0;
    for (int i = 0; i < 10; i++) {
        claude_rx_feed(&rx, big, sizeof big, &m);
    }
    uint8_t tail[] = { 0x02, 'z' };
    assert(claude_rx_feed(&rx, tail, sizeof tail, &m));
    assert(strlen(m.text) == CLAUDE_TEXT_MAX);
}

static void answer_encoding(void)
{
    uint8_t out[5];
    claude_encode_answer(0x01020304, 1, out);
    uint8_t want[5] = { 0x04, 0x03, 0x02, 0x01, 1 };
    assert(memcmp(out, want, 5) == 0);
}

static void time_message_parses_as_text(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    const char *text = "1759555200 -330";
    uint8_t c[32] = { 0x03, 3, 0, 0, 0, 0 };
    memcpy(c + 6, text, strlen(text));
    assert(claude_rx_feed(&rx, c, 6 + strlen(text), &m));
    assert(m.kind == CLAUDE_TIME && m.id == 0 && strcmp(m.text, text) == 0);
}

int main(void)
{
    single_chunk_permission();
    chunked_utf8_roundtrip();
    first_chunk_resets_partial();
    cancel_clears_pending();
    overflow_is_truncated_not_crashing();
    answer_encoding();
    time_message_parses_as_text();
    puts("claude_proto: all tests passed");
    return 0;
}
