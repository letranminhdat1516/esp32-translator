// firmware/test/test_claude_proto.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto
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

static claude_msg_t msg(claude_kind_t kind, uint32_t id, const char *text)
{
    claude_msg_t m;
    memset(&m, 0, sizeof m);
    m.kind = kind;
    m.id = id;
    snprintf(m.text, sizeof m.text, "%s", text);
    return m;
}

/* Feeds kind+id+text in 20-byte writes (default ATT MTU 23 - 3), like the Mac */
static claude_msg_t from_wire(uint8_t kind, uint32_t id, const char *text)
{
    uint8_t payload[CLAUDE_TEXT_MAX + 5] = { kind, (uint8_t)(id & 0xff), (uint8_t)((id >> 8) & 0xff),
                                             (uint8_t)((id >> 16) & 0xff), (uint8_t)(id >> 24) };
    size_t n = 5 + strlen(text);
    memcpy(payload + 5, text, strlen(text));
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    bool done = false;
    for (size_t off = 0; off < n; off += 19) {
        uint8_t chunk[20];
        size_t len = n - off < 19 ? n - off : 19;
        chunk[0] = (off == 0 ? 1 : 0) | (off + len == n ? 2 : 0);
        memcpy(chunk + 1, payload + off, len);
        done = claude_rx_feed(&rx, chunk, len + 1, &m);
    }
    assert(done);
    return m;
}

static void session_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_SESSION, 5, "w 1759555200 1759555260 1\ndự-án\nDone.");
    claude_session_t s;
    assert(m.kind == CLAUDE_SESSION && claude_parse_session(&m, &s));
    assert(s.handle == 5 && s.state == CLAUDE_STATE_WORKING && s.flags == CLAUDE_SESSION_FOCUSED);
    assert(s.since == 1759555200LL && s.updated == 1759555260LL);
    assert(strcmp(s.project, "dự-án") == 0 && strcmp(s.line, "Done.") == 0);
}

static void session_empty_line_and_unseen(void)
{
    claude_msg_t m = msg(CLAUDE_SESSION, 9, "i -5 2 2\np\n");
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(s.state == CLAUDE_STATE_IDLE && s.since == -5 && s.flags == CLAUDE_SESSION_UNSEEN);
    assert(strcmp(s.project, "p") == 0 && s.line[0] == '\0');
}

static void session_rejects_bad_rows(void)
{
    const char *bad[] = {
        "", "w 1 2 0", "w 1 2 0\np", "x 1 2 0\np\nl", "w 1 2\np\nl", "w a 2 0\np\nl",
        "w 1 2 0 9\np\nl", "w 1 2 8\np\nl", "w1 2 3 0\np\nl",
    };
    claude_session_t s;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_SESSION, 5, bad[i]);
        assert(!claude_parse_session(&m, &s));
    }
    claude_msg_t zero = msg(CLAUDE_SESSION, 0, "w 1 2 0\np\nl");
    assert(!claude_parse_session(&zero, &s));
    claude_msg_t other = msg(CLAUDE_QUESTION, 5, "w 1 2 0\np\nl");
    assert(!claude_parse_session(&other, &s));
}

static void session_long_project_is_cut_utf8_safe(void)
{
    char text[CLAUDE_TEXT_MAX + 1] = "e 1 2 0\n";
    for (int i = 0; i < 40; i++) {
        strcat(text, "ữ");   /* 3 bytes each: 120 bytes */
    }
    strcat(text, "\nbye");
    claude_msg_t m = msg(CLAUDE_SESSION, 9, text);
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(strlen(s.project) == 63);   /* 21 whole characters: 64 bytes would split the 22nd */
    assert(strcmp(s.line, "bye") == 0);
}

static const char *QTEXT = "0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue\nCool";

static void question_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_QUESTION, 0x01020304, QTEXT);
    claude_question_t q;
    assert(m.kind == CLAUDE_QUESTION && m.id == 0x01020304 && claude_parse_question(&m, &q));
    assert(q.index == 0 && q.count == 2 && !q.multi && q.nopt == 3);
    assert(strcmp(CLAUDE_Q_STR(&q, project), "proj") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, header), "Color") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, question), "Which color?") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[0]), "Red") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[0]), "Warm") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[1]), "Green") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[1]), "") == 0);
    assert(strcmp(CLAUDE_Q_STR(&q, label[2]), "Blue") == 0 && strcmp(CLAUDE_Q_STR(&q, desc[2]), "Cool") == 0);
    claude_question_t copy = q;   /* offsets, not pointers: a copy stays valid */
    assert(strcmp(CLAUDE_Q_STR(&copy, label[2]), "Blue") == 0);
}

static void question_rejects_bad_shapes(void)
{
    const char *bad[] = {
        "0 2 0 3\nproj\nColor\nWhich color?\nRed\nWarm\nGreen\n\nBlue",   /* one line short */
        "0 2 0 2\nproj\nColor\nQ\nA\na\nB\nb\nC",                       /* one line too many */
        "2 2 0 1\np\nh\nq\nA\na",                                         /* index >= count */
        "0 0 0 1\np\nh\nq\nA\na",                                         /* no questions */
        "0 5 0 1\np\nh\nq\nA\na",                                         /* more than 4 questions */
        "0 1 2 1\np\nh\nq\nA\na",                                         /* multi is not 0/1 */
        "0 1 0 5\np\nh\nq\nA\na\nB\nb\nC\nc\nD\nd\nE\ne",                 /* more than 4 options */
        "0 1 0 0\np\nh\nq",                                               /* no options */
        "0 1 0 1\np\nh\nq\n\nd",                                          /* empty label */
        "0 1 0 1 9\np\nh\nq\nA\na",                                       /* extra number */
        "x 1 0 1\np\nh\nq\nA\na",                                         /* not a number */
    };
    claude_question_t q;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_QUESTION, 3, bad[i]);
        assert(!claude_parse_question(&m, &q));
    }
    claude_msg_t zero = msg(CLAUDE_QUESTION, 0, QTEXT);
    assert(!claude_parse_question(&zero, &q));
}

static void input_encoders_match_the_mac(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    uint8_t masks[2] = { 0x02, 0x05 };
    assert(claude_encode_answers(0x01020304, masks, 2, out) == 8);
    const uint8_t want_answers[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x02, 0x05 };
    assert(memcmp(out, want_answers, 8) == 0);
    assert(claude_encode_answers(0x01020304, masks, 0, out) == 0);
    assert(claude_encode_answers(0x01020304, masks, 5, out) == 0);
    assert(claude_encode_answers(0, masks, 2, out) == 0);

    assert(claude_encode_mode(CLAUDE_BOARD_PICKER, out) == 6);
    const uint8_t want_mode[6] = { 0, 0, 0, 0, 0x20, 2 };
    assert(memcmp(out, want_mode, 6) == 0);

    assert(claude_encode_focus(7, out) == 9);
    const uint8_t want_focus[9] = { 0, 0, 0, 0, 0x21, 7, 0, 0, 0 };
    assert(memcmp(out, want_focus, 9) == 0);
    assert(claude_encode_focus(0, out) == 0);

    uint8_t five[5];
    claude_encode_answer(0x01020304, CLAUDE_DECISION_ALWAYS, five);
    const uint8_t want_always[5] = { 0x04, 0x03, 0x02, 0x01, 3 };
    assert(memcmp(five, want_always, 5) == 0);
}

static void encoders_reject_bad_input(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(claude_encode_mode(CLAUDE_BOARD_OTHER, out) == 6 && out[5] == 0);
    assert(claude_encode_mode(CLAUDE_BOARD_CLAUDE, out) == 6 && out[5] == 1);
    assert(claude_encode_mode(3, out) == 0);      /* not a board mode */
    assert(claude_encode_mode(0xff, out) == 0);
}

static void session_rejects_overflow_and_oversized_fields(void)
{
    claude_session_t s;
    const char *bad[] = {
        "w 99999999999999999999 2 0\np\nl",            /* since overflows int64 */
        "w -99999999999999999999 2 0\np\nl",           /* since underflows */
        "w 1 99999999999999999999 0\np\nl",            /* updated overflows */
        "w 1 2 99999999999999999999\np\nl",            /* flags overflow */
        "w 1 2 00000000000000000000000000000000000000000000000000000000000000000\np\nl",  /* meta line >= 64 bytes */
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_SESSION, 5, bad[i]);
        assert(!claude_parse_session(&m, &s));
    }
    /* the largest int64 still fits */
    claude_msg_t ok = msg(CLAUDE_SESSION, 5, "w 9223372036854775807 -9223372036854775808 0\np\nl");
    assert(claude_parse_session(&ok, &s) && s.since == 9223372036854775807LL);
}

static void parsers_reject_non_terminated_text(void)
{
    claude_msg_t m;
    memset(&m, 'a', sizeof m);   /* no NUL anywhere in text */
    m.kind = CLAUDE_SESSION;
    m.id = 5;
    memcpy(m.text, "w 1 2 0\np\n", 10);
    claude_session_t s;
    assert(!claude_parse_session(&m, &s));
    m.kind = CLAUDE_QUESTION;
    memcpy(m.text, "0 1 0 1\np\nh\nq\nA\n", 16);
    claude_question_t q;
    assert(!claude_parse_question(&m, &q));
}

static void question_rejects_overflowing_numbers(void)
{
    const char *bad[] = {
        "99999999999999999999 1 0 1\np\nh\nq\nA\na",
        "0 18446744073709551617 0 1\np\nh\nq\nA\na",   /* would wrap to 1 */
        "0 1 0 18446744073709551617\np\nh\nq\nA\na",
    };
    claude_question_t q;
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t m = msg(CLAUDE_QUESTION, 3, bad[i]);
        assert(!claude_parse_question(&m, &q));
    }
}

static void split_lines_keeps_the_rest_in_the_last_field(void)
{
    char *f[4];
    char t[] = "p\nBash\nnpm test\nBash(npm test:*)";
    assert(claude_split_lines(t, f, 4) == 4);
    assert(strcmp(f[0], "p") == 0 && strcmp(f[2], "npm test") == 0 && strcmp(f[3], "Bash(npm test:*)") == 0);
    char t2[] = "p\nBash\nls";
    assert(claude_split_lines(t2, f, 4) == 3 && strcmp(f[2], "ls") == 0);
    char t3[] = "a\nb\nc";
    assert(claude_split_lines(t3, f, 2) == 2 && strcmp(f[1], "b\nc") == 0);
}

static void session_voice_flag_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_SESSION, 5, "w 1759555200 1759555260 5\ndự-án\nDone.");
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(s.flags == (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_VOICE));
    claude_msg_t all = msg(CLAUDE_SESSION, 5, "i 1 2 7\np\nl");
    assert(claude_parse_session(&all, &s) && s.flags == 7);
}

static void voice_message_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_VOICE, 9, "f\nXin chào");
    claude_voice_t v;
    assert(m.kind == CLAUDE_VOICE && claude_parse_voice(&m, &v));
    assert(v.id == 9 && v.what == CLAUDE_VOICE_FINAL && strcmp(v.text, "Xin chào") == 0);
    claude_msg_t empty = msg(CLAUDE_VOICE, 9, "f\n");
    assert(claude_parse_voice(&empty, &v) && v.what == CLAUDE_VOICE_FINAL && v.text[0] == '\0');
    const char *good[] = { "p\nchạy", "x\nOpen with cb for voice", "k\nSent to esp32" };
    const char what[] = { CLAUDE_VOICE_PARTIAL, CLAUDE_VOICE_ERROR, CLAUDE_VOICE_DONE };
    for (int i = 0; i < 3; i++) {
        claude_msg_t g = msg(CLAUDE_VOICE, 9, good[i]);
        assert(claude_parse_voice(&g, &v) && v.what == what[i] && strcmp(v.text, strchr(good[i], '\n') + 1) == 0);
    }
    const char *bad[] = { "", "f", "fx\nabc", "q\nabc", "f abc" };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t b = msg(CLAUDE_VOICE, 9, bad[i]);
        assert(!claude_parse_voice(&b, &v));
    }
    claude_msg_t zero = msg(CLAUDE_VOICE, 0, "f\nx");
    assert(!claude_parse_voice(&zero, &v));
    claude_msg_t other = msg(CLAUDE_FINISHED, 9, "f\nx");
    assert(!claude_parse_voice(&other, &v));
}

static void voice_encoders_match_the_mac(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(claude_encode_voice_start(0x0A0B0C0D, CLAUDE_VOICE_FOR_OTHER, 2, 0x01020304, out) == 10);
    const uint8_t want_other[10] = { 0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01 };
    assert(memcmp(out, want_other, 10) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 10);
    const uint8_t want_command[10] = { 9, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0 };
    assert(memcmp(out, want_command, 10) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_DENY, 0, 7, out) == 10 && out[5] == 0x02);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_STOP, out) == 5);
    const uint8_t want_stop[5] = { 9, 0, 0, 0, 0x31 };
    assert(memcmp(out, want_stop, 5) == 0);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_CANCEL, out) == 5 && out[4] == 0x32);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_SEND, out) == 5 && out[4] == 0x33);
    /* Other answers ride on the unchanged answers input: bit 7 */
    uint8_t masks[2] = { 0x80, 0x05 };
    assert(claude_encode_answers(0x01020304, masks, 2, out) == 8);
    const uint8_t want_answers[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x80, 0x05 };
    assert(memcmp(out, want_answers, 8) == 0);
}

static void voice_encoders_refuse_bad_input(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(claude_encode_voice_start(0, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);          /* voice 0 */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 0, 0, out) == 0);          /* target 0 */
    assert(claude_encode_voice_start(9, 3, 0, 5, out) == 0);                                 /* purpose */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 1, 5, out) == 0);          /* question */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_DENY, 1, 5, out) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_OTHER, CLAUDE_Q_MAX, 5, out) == 0);
    assert(claude_encode_voice(0, CLAUDE_INPUT_VOICE_STOP, out) == 0);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_START, out) == 0);                      /* not 5 bytes */
    assert(claude_encode_voice(9, 0x34, out) == 0);
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
    session_parses();
    session_empty_line_and_unseen();
    session_rejects_bad_rows();
    session_long_project_is_cut_utf8_safe();
    question_parses();
    question_rejects_bad_shapes();
    input_encoders_match_the_mac();
    split_lines_keeps_the_rest_in_the_last_field();
    encoders_reject_bad_input();
    session_rejects_overflow_and_oversized_fields();
    parsers_reject_non_terminated_text();
    question_rejects_overflowing_numbers();
    session_voice_flag_parses();
    voice_message_parses();
    voice_encoders_match_the_mac();
    voice_encoders_refuse_bad_input();
    puts("claude_proto: all tests passed");
    return 0;
}
