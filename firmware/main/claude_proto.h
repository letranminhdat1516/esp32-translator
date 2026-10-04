/*
 * Claude companion wire format (Mac daemon <-> board), pure C, host-tested in firmware/test/test_claude_proto.c.
 *
 * Mac -> board (request characteristic): BLE writes [flags u8][payload], flags bit0 = first, bit1 = last;
 * payload [kind u8][id u32 LE][UTF-8 text, at most CLAUDE_TEXT_MAX bytes]:
 *   0 permission      id = request  "project\ntool\nsummary[\nrule]"  (rule line <=> Always allow offered)
 *   1 finished        fresh id      "project\nlast line"               (focused session only)
 *   2 cancel          id = request  ""                                 (a permission or a whole question set)
 *   3 time            id 0          "<unix seconds> <UTC offset minutes>" (clock.h)
 *   4 session         id = handle   "<state> <since> <updated> <flags>\nproject\nlast line"
 *   5 session remove  id = handle   ""
 *   6 sessions clear  id 0          ""                                 (first message of every full sync)
 *   7 question page   id = request  "<index> <count> <multi> <nopt>\nproject\nheader\nquestion\n(label\ndesc) x nopt"
 *
 * Board -> Mac (answer characteristic, notify, at most CLAUDE_INPUT_MAX bytes):
 *   [id u32 LE][1|2|3]                   allow / deny / always allow
 *   [id u32 LE][0x10][n][mask x n]       question answers, bit i of mask q = option i of question q
 *   [0 u32][0x20][mode]                  board mode (CLAUDE_BOARD_*)
 *   [0 u32][0x21][handle u32 LE]         focus this session
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_TEXT_MAX 400

typedef enum {
    CLAUDE_PERMISSION = 0,
    CLAUDE_FINISHED = 1,
    CLAUDE_CANCEL = 2,
    CLAUDE_TIME = 3,
    CLAUDE_SESSION = 4,
    CLAUDE_SESSION_REMOVE = 5,
    CLAUDE_SESSIONS_CLEAR = 6,
    CLAUDE_QUESTION = 7,
} claude_kind_t;

typedef struct {
    claude_kind_t kind;
    uint32_t id;
    char text[CLAUDE_TEXT_MAX + 1];
} claude_msg_t;

typedef struct {
    uint8_t buf[CLAUDE_TEXT_MAX + 5];
    size_t len;
} claude_rx_t;

/* Feeds one BLE write ([flags][payload...]). Returns true and fills *out when the last chunk arrives. */
bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out);
void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5]);

/* Length of the longest prefix of s[0..n) that does not end inside a UTF-8 sequence */
size_t claude_utf8_cut(const char *s, size_t n);
/* Splits text in place at '\n' into at most max fields (the last one keeps any further newlines). Returns the count. */
size_t claude_split_lines(char *text, char **fields, size_t max);

/* Sessions (kind 4) */
#define CLAUDE_PROJECT_MAX     64
#define CLAUDE_STATE_NEEDS_YOU 'n'
#define CLAUDE_STATE_WORKING   'w'
#define CLAUDE_STATE_IDLE      'i'
#define CLAUDE_STATE_ENDED     'e'
#define CLAUDE_SESSION_FOCUSED 0x01
#define CLAUDE_SESSION_UNSEEN  0x02

typedef struct {
    uint32_t handle;   /* never 0 */
    char state;        /* CLAUDE_STATE_* */
    uint8_t flags;     /* CLAUDE_SESSION_* */
    int64_t since;     /* Unix seconds: current state began */
    int64_t updated;   /* Unix seconds: last event (picker order) */
    char project[CLAUDE_PROJECT_MAX + 1];
    char line[CLAUDE_TEXT_MAX + 1];
} claude_session_t;

bool claude_parse_session(const claude_msg_t *m, claude_session_t *out);

/* Question pages (kind 7) */
#define CLAUDE_Q_MAX   4
#define CLAUDE_OPT_MAX 4

typedef struct {
    uint8_t index;   /* 0-based page */
    uint8_t count;   /* pages in the request, 1..CLAUDE_Q_MAX */
    uint8_t nopt;    /* 1..CLAUDE_OPT_MAX */
    bool multi;
    /* Offsets into buf (a copy stays valid) */
    uint16_t project, header, question, label[CLAUDE_OPT_MAX], desc[CLAUDE_OPT_MAX];
    char buf[CLAUDE_TEXT_MAX + 1];
} claude_question_t;

#define CLAUDE_Q_STR(q, field) ((const char *)(q)->buf + (q)->field)

bool claude_parse_question(const claude_msg_t *m, claude_question_t *out);

/* Board -> Mac */
#define CLAUDE_INPUT_MAX       10
#define CLAUDE_DECISION_ALLOW  1
#define CLAUDE_DECISION_DENY   2
#define CLAUDE_DECISION_ALWAYS 3
#define CLAUDE_INPUT_ANSWERS   0x10
#define CLAUDE_INPUT_MODE      0x20
#define CLAUDE_INPUT_FOCUS     0x21
#define CLAUDE_BOARD_OTHER     0
#define CLAUDE_BOARD_CLAUDE    1
#define CLAUDE_BOARD_PICKER    2

/* Each returns the byte count to send, or 0 when the input is refused (id 0, handle 0, bad n) */
size_t claude_encode_answers(uint32_t id, const uint8_t *masks, size_t n, uint8_t out[CLAUDE_INPUT_MAX]);
size_t claude_encode_mode(uint8_t mode, uint8_t out[CLAUDE_INPUT_MAX]);
size_t claude_encode_focus(uint32_t handle, uint8_t out[CLAUDE_INPUT_MAX]);
