/*
 * Apple Notification Center Service (ANCS) for the board as ANCS client: Apple's wire format and (Task 2) the
 * notice flow. Pure C, host-tested in firmware/test/test_ancs.c. The iPhone is the GATT server ("Notification
 * Provider"); ancs_client.c does the GATT work.
 *   Notification Source (notify)    [event u8][flags u8][category u8][count u8][uid u32 LE]
 *   Control Point (write with rsp)  [0][uid u32 LE]{[attr][max u16 LE: Title/Subtitle/Message only]}  get attributes
 *                                   [2][uid u32 LE][action u8]                                          perform action
 *   Data Source (notify)            [0][uid u32 LE]{[attr][len u16 LE][UTF-8]}, split over notifications at will
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* 128-bit UUIDs as little-endian bytes, for NimBLE's BLE_UUID128_INIT(...) */
/* 7905F431-B5CE-4E99-A40F-4B1E122D00D0 */
#define ANCS_UUID_SVC     0xd0, 0x00, 0x2d, 0x12, 0x1e, 0x4b, 0x0f, 0xa4, 0x99, 0x4e, 0xce, 0xb5, 0x31, 0xf4, 0x05, 0x79
/* 9FBF120D-6301-42D9-8C58-25E699A21DBD */
#define ANCS_UUID_SOURCE  0xbd, 0x1d, 0xa2, 0x99, 0xe6, 0x25, 0x58, 0x8c, 0xd9, 0x42, 0x01, 0x63, 0x0d, 0x12, 0xbf, 0x9f
/* 69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9 */
#define ANCS_UUID_CONTROL 0xd9, 0xd9, 0xaa, 0xfd, 0xbd, 0x9b, 0x21, 0x98, 0xa8, 0x49, 0xe1, 0x45, 0xf3, 0xd8, 0xd1, 0x69
/* 22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB */
#define ANCS_UUID_DATA    0xfb, 0x7b, 0x7c, 0xce, 0x6a, 0xb3, 0x44, 0xbe, 0xb5, 0x4b, 0xd6, 0x24, 0xe9, 0xc6, 0xea, 0x22

/* The only app whose notifications the board shows: exact App Identifier, verified on the user's iPhone in
 * Phase 4 Task 1 (docs/superpowers/notes/2026-10-05-ancs-discovery.md) */
#define ANCS_CLAUDE_APP_ID "com.anthropic.claude"

#define ANCS_EVENT_ADDED    0
#define ANCS_EVENT_MODIFIED 1
#define ANCS_EVENT_REMOVED  2

#define ANCS_FLAG_SILENT       0x01
#define ANCS_FLAG_IMPORTANT    0x02
#define ANCS_FLAG_PRE_EXISTING 0x04
#define ANCS_FLAG_POSITIVE     0x08
#define ANCS_FLAG_NEGATIVE     0x10

#define ANCS_CMD_GET_NOTIF_ATTRS 0
#define ANCS_CMD_PERFORM_ACTION  2

#define ANCS_ATTR_APP_ID   0
#define ANCS_ATTR_TITLE    1
#define ANCS_ATTR_SUBTITLE 2
#define ANCS_ATTR_MESSAGE  3
#define ANCS_ATTR_POSITIVE 6
#define ANCS_ATTR_NEGATIVE 7

#define ANCS_ACTION_POSITIVE 0
#define ANCS_ACTION_NEGATIVE 1

#define ANCS_TITLE_MAX    64
#define ANCS_SUBTITLE_MAX 64
#define ANCS_MESSAGE_MAX  240
#define ANCS_LABEL_MAX    32
#define ANCS_CMD_MAX      20    /* longest Control Point command we write (details: 16) */
#define ANCS_REPLY_MAX    640   /* longest Data Source reply we accept (details: ~400) */

typedef struct {
    uint8_t event;      /* ANCS_EVENT_* */
    uint8_t flags;      /* ANCS_FLAG_* */
    uint8_t category;
    uint8_t count;
    uint32_t uid;       /* any value, 0 included */
} ancs_source_t;

/* Exactly 8 bytes with a known event */
bool ancs_parse_source(const uint8_t *data, size_t len, ancs_source_t *out);

/* Attribute lists: the lookup (app id only) and the details of a Claude notification */
extern const uint8_t ANCS_APP_ATTRS[1];
extern const uint8_t ANCS_DETAIL_ATTRS[5];

/* Get Notification Attributes for ids[0..n): Title / Subtitle / Message carry their *_MAX. Returns the length,
 * 0 if n is 0 or out_size is too small. */
size_t ancs_encode_get_attrs(uint32_t uid, const uint8_t *ids, size_t n, uint8_t *out, size_t out_size);
/* Perform Notification Action: 6 bytes, or 0 for an unknown action */
size_t ancs_encode_action(uint32_t uid, uint8_t action, uint8_t out[6]);

/* Data Source reply reassembly for one Get Notification Attributes command */
typedef struct {
    uint8_t buf[ANCS_REPLY_MAX];
    size_t len;
    uint32_t uid;
    uint8_t want;      /* attributes asked */
    bool active;       /* a reply is expected */
} ancs_reply_t;

typedef enum { ANCS_REPLY_MORE = 0, ANCS_REPLY_DONE, ANCS_REPLY_BAD } ancs_reply_status_t;

void ancs_reply_start(ancs_reply_t *r, uint32_t uid, uint8_t want);
void ancs_reply_clear(ancs_reply_t *r);   /* zeroes everything (no value outlives its reply) */
/* MORE: wait for the next notification. DONE: all `want` attributes are in. BAD: not our reply (other command
 * or uid), too long, or nothing expected. DONE and BAD end the reply. */
ancs_reply_status_t ancs_reply_feed(ancs_reply_t *r, const uint8_t *chunk, size_t len);
/* After DONE: the value of attribute id (not NUL-terminated); false when it is not in the reply */
bool ancs_reply_attr(const ancs_reply_t *r, uint8_t id, const uint8_t **value, uint16_t *len);

/* UTF-8 for the board fonts: drops invalid bytes and characters the fonts lack (emoji, CJK, ...), turns control
 * characters and line separators into spaces, folds whitespace runs, trims, and cuts at a character boundary
 * to fit out_size - 1 bytes. Always NUL-terminates (out_size >= 1). Returns the length. */
size_t ancs_clean_text(const uint8_t *src, size_t len, char *out, size_t out_size);

/* ---- notice flow (Task 2) ----
 * Every Notification Source event goes to ancs_flow_on_source(). ancs_flow_next() says which Control Point
 * command to write (one outstanding at a time): first the App Identifier alone; only for ANCS_CLAUDE_APP_ID
 * the details (title, subtitle, message, action labels). Data Source bytes go to ancs_flow_on_data(). The
 * board holds at most one notice (the one on screen); nothing from other apps is asked beyond the app id, and
 * every reply is zeroed once read. Pre-existing notifications (the dump at subscription) are ignored. A reply
 * missing for ANCS_REPLY_TIMEOUT_MS is given up at the next ancs_flow_next() (no timer). Data Source bytes that
 * do not start with the reply header of the command in flight (another uid's reply, the rest of a timed-out one)
 * are ignored: the command keeps waiting for its own reply. */
#define ANCS_QUEUE_MAX        8
#define ANCS_REPLY_TIMEOUT_MS 3000

typedef struct {
    uint32_t uid;
    uint8_t flags;                           /* ANCS_FLAG_* of the latest event */
    char title[ANCS_TITLE_MAX + 1];
    char subtitle[ANCS_SUBTITLE_MAX + 1];
    char message[ANCS_MESSAGE_MAX + 1];
    char positive[ANCS_LABEL_MAX + 1];       /* "" = no positive action */
    char negative[ANCS_LABEL_MAX + 1];       /* "" = no negative action */
} ancs_notice_t;

typedef enum { ANCS_STEP_IDLE = 0, ANCS_STEP_APP, ANCS_STEP_DETAILS } ancs_step_t;

typedef struct {
    uint32_t uid;
    uint8_t flags;
    ancs_step_t step;                        /* APP: look up the app id; DETAILS: a known Claude notification */
} ancs_queued_t;

typedef struct {
    ancs_queued_t queue[ANCS_QUEUE_MAX];
    int nq;
    ancs_step_t step;                        /* the command outstanding; IDLE = none */
    uint32_t uid;                            /* its notification */
    uint8_t flags;
    bool dropped;                            /* removed on the iPhone meanwhile: its reply is thrown away */
    uint32_t sent_ms;
    ancs_reply_t reply;
    bool shown;                              /* notice holds the notification on the board */
    ancs_notice_t notice;
} ancs_flow_t;

typedef enum {
    ANCS_OUT_NONE = 0,
    ANCS_OUT_SHOW,     /* a new Claude notice (chime unless ANCS_FLAG_SILENT) */
    ANCS_OUT_UPDATE,   /* the notice on screen changed (no chime) */
    ANCS_OUT_GONE,     /* the notice on screen was removed on the iPhone (or its uid reused for a new one) */
} ancs_out_t;

bool ancs_app_allowed(const uint8_t *id, size_t len);   /* exactly ANCS_CLAUDE_APP_ID */
void ancs_flow_init(ancs_flow_t *f);                    /* also on every (re)subscription and disconnect */
ancs_out_t ancs_flow_on_source(ancs_flow_t *f, const ancs_source_t *ev);
size_t ancs_flow_next(ancs_flow_t *f, uint32_t now_ms, uint8_t out[ANCS_CMD_MAX]);
ancs_out_t ancs_flow_on_data(ancs_flow_t *f, const uint8_t *chunk, size_t len);
void ancs_flow_on_error(ancs_flow_t *f);                /* the outstanding command was refused or not sent */
/* Perform Notification Action bytes for the notice on screen only (uid matches, that action offered); else 0 */
size_t ancs_flow_action(const ancs_flow_t *f, uint32_t uid, uint8_t action, uint8_t out[6]);
void ancs_flow_close(ancs_flow_t *f, uint32_t uid);     /* the board closed that notice: forget it */

/* ---- action gate ----
 * The positive action (Allow-like) needs an unlocked board: a notice may show over the lock, and the lock must
 * not be a way to approve something. The negative action and Close always work. */
bool ancs_action_allowed(uint8_t action, bool locked);

/* ---- GATT timeout guard ----
 * NimBLE drops the whole link when a GATT client procedure times out (30 s). iOS may hold the answer to the
 * ANCS CCCD write while its "share notifications" prompt is unanswered, so ANCS could cost the translator its
 * link, again on every reconnect. ancs_client.c remembers (RAM, this boot only) every peer, by identity address,
 * whose link dropped while an ANCS GATT procedure (discovery, CCCD write, Control Point write) was outstanding,
 * or whose ANCS procedure timed out, and never tries ANCS on it again this boot: one drop per peer per boot at
 * most. Past ANCS_GUARD_MAX peers, ANCS is skipped for every peer. */
#define ANCS_GUARD_MAX  4
#define ANCS_PEER_ID_LEN 7   /* address type + 6 address bytes */

typedef struct {
    uint8_t peers[ANCS_GUARD_MAX][ANCS_PEER_ID_LEN];
    int n;
    bool all;   /* the list overflowed: skip everyone */
} ancs_guard_t;

void ancs_guard_init(ancs_guard_t *g);
/* ANCS must not be tried on this peer this boot */
bool ancs_guard_skips(const ancs_guard_t *g, const uint8_t id[ANCS_PEER_ID_LEN]);
/* The peer's link dropped (or an ANCS procedure on it timed out). risky: an ANCS GATT procedure was outstanding
 * or timed out. Returns true when the peer is newly remembered. */
bool ancs_guard_on_drop(ancs_guard_t *g, const uint8_t id[ANCS_PEER_ID_LEN], bool risky);
