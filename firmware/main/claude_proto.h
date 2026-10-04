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
 *   8 voice           id = voice id    "<p|f|x|k>\ntext"   partial / final (what Send types) / error / done
 *
 * Board -> Mac (answer characteristic, notify, at most CLAUDE_INPUT_MAX bytes):
 *   [id u32 LE][1|2|3]                   allow / deny / always allow
 *   [id u32 LE][0x10][n][mask x n]       question answers, bit i of mask q = option i of question q
 *   [0 u32][0x20][mode]                  board mode (CLAUDE_BOARD_*)
 *   [0 u32][0x21][handle u32 LE]         focus this session
 *   [voice u32][0x30][purpose u8][target u32 LE]   voice capture starts (purpose low nibble CLAUDE_VOICE_FOR_*,
 *                                        high nibble the question index for Other)
 *   [voice u32][0x31] / [0x32] / [0x33]  audio complete / cancel / send the final transcript
 *   Question answers: bit 7 of a mask = the spoken Other answer of that question.
 * Voice audio goes on its own characteristic (ble_link.c), never through these messages.
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
    CLAUDE_VOICE = 8,
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
#define CLAUDE_SESSION_VOICE   0x04   /* the session runs in a tmux pane the Mac can type into (Speak usable) */

typedef struct {
    uint32_t handle;   /* never 0 */
    char state;        /* CLAUDE_STATE_* */
    uint8_t flags;     /* CLAUDE_SESSION_* (0..7) */
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

/* Voice (kind 8) */
#define CLAUDE_VOICE_TEXT_MAX 300   /* final transcript: Mac VoiceText.maxBytes */
#define CLAUDE_VOICE_PARTIAL  'p'
#define CLAUDE_VOICE_FINAL    'f'
#define CLAUDE_VOICE_ERROR    'x'
#define CLAUDE_VOICE_DONE     'k'

typedef struct {
    uint32_t id;                      /* voice id, never 0 */
    char what;                        /* CLAUDE_VOICE_* */
    char text[CLAUDE_TEXT_MAX + 1];
} claude_voice_t;

bool claude_parse_voice(const claude_msg_t *m, claude_voice_t *out);

#define CLAUDE_INPUT_VOICE_START  0x30
#define CLAUDE_INPUT_VOICE_STOP   0x31
#define CLAUDE_INPUT_VOICE_CANCEL 0x32
#define CLAUDE_INPUT_VOICE_SEND   0x33
#define CLAUDE_VOICE_FOR_COMMAND  0   /* typed into the session's tmux pane; target = session handle */
#define CLAUDE_VOICE_FOR_OTHER    1   /* spoken Other answer; target = question request id, question = page */
#define CLAUDE_VOICE_FOR_DENY     2   /* deny with the spoken reason; target = permission request id */

/* 10 bytes, or 0 when refused (voice or target 0, unknown purpose, a question index for anything but Other) */
size_t claude_encode_voice_start(uint32_t voice, uint8_t purpose, uint8_t question, uint32_t target,
                                 uint8_t out[CLAUDE_INPUT_MAX]);
/* code CLAUDE_INPUT_VOICE_STOP / CANCEL / SEND: 5 bytes, or 0 when refused */
size_t claude_encode_voice(uint32_t voice, uint8_t code, uint8_t out[CLAUDE_INPUT_MAX]);
