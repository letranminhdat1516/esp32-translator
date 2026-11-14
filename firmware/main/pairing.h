/*
 * Pairing by code (pure C, host-tested in firmware/test/test_pairing.c; ble_link.c applies it, pair_ui.c shows it).
 * LE Secure Connections numeric comparison only: the iPhone and the board show the same 6 digits, the owner
 * confirms on both. The translator characteristics need an encrypted, authenticated link with a 16-byte key from an
 * LE Secure Connections bond; board info does not (the app reads it before pairing).
 *
 * Request flow: idle -> showing the code -> accepted / rejected / timed out (PAIR_TIMEOUT_US) / cancelled -> idle.
 * A request is refused, before anything is drawn, when:
 *   - it is not a numeric comparison (passkey entry, OOB): PAIR_BEGIN_REJECT_METHOD
 *   - the board is locked: PAIR_BEGIN_REJECT_LOCKED (the caller shows a short notice, never the code). Checked
 *     before the rate limit and not recorded: the owner's phone retrying while the board is locked must not use up
 *     its budget for when the board is unlocked
 *   - its peer address asked less than PAIR_RATE_GAP_US ago, or PAIR_RATE_MAX times within PAIR_RATE_WINDOW_US,
 *     or all peers together asked PAIR_GLOBAL_MAX times within that window: PAIR_BEGIN_REJECT_RATE (the caller
 *     shows a short "too many requests" notice)
 *   - another link's code is on screen: PAIR_BEGIN_REJECT_BUSY (the newcomer loses, the shown code stays)
 * The two notices are rate-limited themselves (pair_notice_due): a stream of requests cannot keep the panel lit.
 * Every request gets an id; an answer only counts for the request (link + id) it was given for, and only after the
 * code was up for PAIR_ARM_US (a tap meant for the previous screen cannot confirm a new code).
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define PAIR_TIMEOUT_US   (30LL * 1000 * 1000)
#define PAIR_TIMEOUT_MS   ((uint32_t)(PAIR_TIMEOUT_US / 1000))
#define PAIR_ARM_US       (1000LL * 1000)          /* answers ignored this long after a code appears */
#define PAIR_ARM_MS       ((uint32_t)(PAIR_ARM_US / 1000))
#define PAIR_NOTICE_MS    2000u                    /* "unlock to pair" / "too many requests" notice */
#define PAIR_LOCKED_NOTICE_GAP_US (10LL * 1000 * 1000)   /* "unlock to pair" at most every 10 s */
#define PAIR_RATE_NOTICE_GAP_US   (60LL * 1000 * 1000)   /* "too many requests" at most once a minute */
#define PAIR_CONN_NONE    0xFFFF                   /* = BLE_HS_CONN_HANDLE_NONE */
#define PAIR_ID_NONE      0u

/* Rate limit: per peer address and for all peers together (an attacker can change its address) */
#define PAIR_RATE_GAP_US    (10LL * 1000 * 1000)   /* one attempt per 10 s per peer */
#define PAIR_RATE_WINDOW_US (600LL * 1000 * 1000)  /* ... and at most PAIR_RATE_MAX per 10 min */
#define PAIR_RATE_MAX       5
#define PAIR_RATE_PEERS     8                      /* peers remembered (least recently seen is dropped) */
#define PAIR_GLOBAL_MAX     10                     /* attempts per PAIR_RATE_WINDOW_US, all peers */
#define PAIR_ADDR_LEN       7                      /* address type + 6 bytes */

/* A code on screen holds deep sleep off; at most this many requests per idle period may do so */
#define PAIR_SLEEP_HOLDS_MAX 3

typedef enum { PAIR_IDLE = 0, PAIR_SHOWING } pair_phase_t;

typedef enum {
    PAIR_OUT_NONE = 0,   /* nothing to do (no request, a stale / early answer) */
    PAIR_OUT_ACCEPT,
    PAIR_OUT_REJECT,
    PAIR_OUT_TIMEOUT,    /* reject it and close the view */
} pair_outcome_t;

typedef enum {
    PAIR_BEGIN_SHOW = 0,        /* show the code (a request on the same link replaces its own older one) */
    PAIR_BEGIN_REJECT_METHOD,   /* not numeric comparison: drop the link */
    PAIR_BEGIN_REJECT_RATE,     /* reject, nothing on screen */
    PAIR_BEGIN_REJECT_LOCKED,   /* reject, short "unlock to pair" notice */
    PAIR_BEGIN_REJECT_BUSY,     /* reject, nothing on screen: another link's code stays up */
} pair_begin_t;

typedef enum { PAIR_NOTICE_LOCKED = 0, PAIR_NOTICE_RATE, PAIR_NOTICE_COUNT } pair_notice_t;

typedef struct {
    bool used;
    uint8_t addr[PAIR_ADDR_LEN];
    uint8_t n;                       /* attempts recorded in t[] (at most PAIR_RATE_MAX, newest last) */
    int64_t t[PAIR_RATE_MAX];
} pair_peer_t;

typedef struct {
    pair_phase_t phase;
    uint16_t conn;
    uint32_t passkey;
    uint32_t id;                     /* request on screen (PAIR_ID_NONE when idle) */
    uint32_t next_id;
    int64_t shown_us;
    int64_t deadline_us;
    pair_peer_t peers[PAIR_RATE_PEERS];
    uint8_t global_n;
    int64_t global_t[PAIR_GLOBAL_MAX];   /* newest last */
    bool notice_shown[PAIR_NOTICE_COUNT];
    int64_t notice_us[PAIR_NOTICE_COUNT];   /* when each notice was last shown */
} pair_t;

static inline void pair_init(pair_t *p)
{
    memset(p, 0, sizeof(*p));
    p->phase = PAIR_IDLE;
    p->conn = PAIR_CONN_NONE;
    p->id = PAIR_ID_NONE;
    p->next_id = 1;
}

/* Push now into a newest-last history of at most max entries */
static inline void pair_hist_push(int64_t *t, uint8_t *n, int max, int64_t now_us)
{
    if (*n == max) {
        memmove(t, t + 1, sizeof(t[0]) * (size_t)(max - 1));
        (*n)--;
    }
    t[(*n)++] = now_us;
}

/* The history allows one more attempt: at most max within the window (oldest of the last max is out of it) */
static inline bool pair_hist_room(const int64_t *t, uint8_t n, int max, int64_t now_us)
{
    return n < max || now_us - t[0] >= PAIR_RATE_WINDOW_US;
}

/* Rate check for one attempt from addr; records it when allowed. Refused attempts are not recorded (a phone that
 * retries too fast is not locked out for longer). */
static inline bool pair_rate_allow(pair_t *p, const uint8_t addr[PAIR_ADDR_LEN], int64_t now_us)
{
    pair_peer_t *peer = NULL;
    pair_peer_t *lru = &p->peers[0];
    for (int i = 0; i < PAIR_RATE_PEERS; i++) {
        pair_peer_t *e = &p->peers[i];
        if (e->used && memcmp(e->addr, addr, PAIR_ADDR_LEN) == 0) {
            peer = e;
            break;
        }
        /* eviction candidate: a free slot, else the one seen longest ago */
        if (lru->used && (!e->used || e->t[e->n - 1] < lru->t[lru->n - 1])) {
            lru = e;
        }
    }
    if (peer != NULL) {
        if (now_us - peer->t[peer->n - 1] < PAIR_RATE_GAP_US || !pair_hist_room(peer->t, peer->n, PAIR_RATE_MAX, now_us)) {
            return false;
        }
    }
    if (!pair_hist_room(p->global_t, p->global_n, PAIR_GLOBAL_MAX, now_us)) {
        return false;
    }
    if (peer == NULL) {
        peer = lru;
        memset(peer, 0, sizeof(*peer));
        peer->used = true;
        memcpy(peer->addr, addr, PAIR_ADDR_LEN);
    }
    pair_hist_push(peer->t, &peer->n, PAIR_RATE_MAX, now_us);
    pair_hist_push(p->global_t, &p->global_n, PAIR_GLOBAL_MAX, now_us);
    return true;
}

/* A passkey action arrived on conn from addr. numcmp: it is a numeric comparison; locked: the board is locked.
 * PAIR_BEGIN_SHOW: the code is now on screen as request p->id (the caller draws it); anything else: the caller
 * rejects this request (pair_begin_t) and the shown one, if any, is untouched. */
static inline pair_begin_t pair_begin(pair_t *p, uint16_t conn, const uint8_t addr[PAIR_ADDR_LEN], bool numcmp,
                                      bool locked, uint32_t passkey, int64_t now_us)
{
    if (!numcmp) {
        return PAIR_BEGIN_REJECT_METHOD;
    }
    if (locked) {
        return PAIR_BEGIN_REJECT_LOCKED;
    }
    if (!pair_rate_allow(p, addr, now_us)) {
        return PAIR_BEGIN_REJECT_RATE;
    }
    if (p->phase == PAIR_SHOWING && p->conn != conn) {
        return PAIR_BEGIN_REJECT_BUSY;
    }
    p->phase = PAIR_SHOWING;
    p->conn = conn;
    p->passkey = passkey % 1000000u;
    p->id = p->next_id++;
    if (p->next_id == PAIR_ID_NONE) {
        p->next_id = 1;
    }
    p->shown_us = now_us;
    p->deadline_us = now_us + PAIR_TIMEOUT_US;
    return PAIR_BEGIN_SHOW;
}

/* A refusal wants its notice drawn: true (and noted) when that notice was not shown within its gap
 * (PAIR_LOCKED_NOTICE_GAP_US, PAIR_RATE_NOTICE_GAP_US); false: stay silent this time. */
static inline bool pair_notice_due(pair_t *p, pair_notice_t which, int64_t now_us)
{
    int64_t gap = which == PAIR_NOTICE_RATE ? PAIR_RATE_NOTICE_GAP_US : PAIR_LOCKED_NOTICE_GAP_US;
    if (p->notice_shown[which] && now_us - p->notice_us[which] < gap) {
        return false;
    }
    p->notice_shown[which] = true;
    p->notice_us[which] = now_us;
    return true;
}

/* The owner tapped Đúng (yes) or Sai on the view of request (conn, id). Ignored (PAIR_OUT_NONE, the request stays)
 * when that request is no longer the one on screen or the code has been up less than PAIR_ARM_US. Late taps
 * (after the deadline) count as a timeout. Otherwise ends the request. */
static inline pair_outcome_t pair_answer(pair_t *p, uint16_t conn, uint32_t id, bool yes, int64_t now_us)
{
    if (p->phase != PAIR_SHOWING || p->conn != conn || p->id != id || id == PAIR_ID_NONE) {
        return PAIR_OUT_NONE;
    }
    if (now_us - p->shown_us < PAIR_ARM_US) {
        return PAIR_OUT_NONE;
    }
    p->phase = PAIR_IDLE;
    p->id = PAIR_ID_NONE;
    if (now_us >= p->deadline_us) {
        return PAIR_OUT_TIMEOUT;
    }
    return yes ? PAIR_OUT_ACCEPT : PAIR_OUT_REJECT;
}

/* The board locked while a code was up: reject it (PAIR_OUT_REJECT, p->conn tells which link) and close */
static inline pair_outcome_t pair_cancel(pair_t *p)
{
    if (p->phase != PAIR_SHOWING) {
        return PAIR_OUT_NONE;
    }
    p->phase = PAIR_IDLE;
    p->id = PAIR_ID_NONE;
    return PAIR_OUT_REJECT;
}

/* Timer check: PAIR_OUT_TIMEOUT ends the request (the caller rejects it and closes the view). */
static inline pair_outcome_t pair_tick(pair_t *p, int64_t now_us)
{
    if (p->phase != PAIR_SHOWING || now_us < p->deadline_us) {
        return PAIR_OUT_NONE;
    }
    p->phase = PAIR_IDLE;
    p->id = PAIR_ID_NONE;
    return PAIR_OUT_TIMEOUT;
}

/* Pairing finished (either way) or the link went away. True: the view was showing this link's code, close it. */
static inline bool pair_end(pair_t *p, uint16_t conn)
{
    if (p->phase != PAIR_SHOWING || p->conn != conn) {
        return false;
    }
    p->phase = PAIR_IDLE;
    p->id = PAIR_ID_NONE;
    return true;
}

/* The 6 digits as both phones show them: zero-padded, "004213" */
static inline void pair_code_text(uint32_t passkey, char out[7])
{
    snprintf(out, 7, "%06u", (unsigned)(passkey % 1000000u));
}

/* A link's security as NimBLE reports it (ble_gap_conn_desc.sec_state + the stored bond's sc flag) */
typedef struct {
    bool encrypted;
    bool authenticated;   /* MITM: the codes were compared */
    uint8_t key_size;     /* bytes */
    bool sc_bond;         /* the bond was made with LE Secure Connections */
} pair_sec_t;

/* Paired by code the way this firmware requires: encrypted, authenticated, full 16-byte key, SC bond */
static inline bool pair_link_secure(const pair_sec_t *s)
{
    return s->encrypted && s->authenticated && s->key_size == 16 && s->sc_bond;
}

/* Characteristic access given the link's security. Board info stays open; text, control and audio need
 * pair_link_secure. */
typedef enum { PAIR_CHR_INFO = 0, PAIR_CHR_AUDIO, PAIR_CHR_TEXT, PAIR_CHR_CTRL } pair_chr_t;

static inline bool pair_chr_allowed(pair_chr_t chr, const pair_sec_t *s)
{
    if (chr == PAIR_CHR_INFO) {
        return true;
    }
    return pair_link_secure(s);
}

/* The link just encrypted. A key that is not good enough (a Just Works or legacy bond from older firmware, a short
 * key) must be replaced: request pairing once per link (true), so a Secure Connections numeric comparison runs. */
static inline bool pair_should_upgrade(const pair_sec_t *s, bool already_requested)
{
    return s->encrypted && !pair_link_secure(s) && !already_requested;
}

/* Deep sleep vs. a code on screen. showing_id: the request on screen, PAIR_ID_NONE if none. True: hold sleep off
 * now. Each distinct request counts once; past PAIR_SLEEP_HOLDS_MAX per idle period (pair_sleep_reset when the app
 * connects) codes no longer hold the board awake, so a stream of remote requests cannot drain the battery. */
typedef struct {
    uint32_t last_id;
    uint8_t holds;
} pair_sleep_t;

static inline void pair_sleep_reset(pair_sleep_t *s)
{
    s->last_id = PAIR_ID_NONE;
    s->holds = 0;
}

static inline bool pair_sleep_hold(pair_sleep_t *s, uint32_t showing_id)
{
    if (showing_id == PAIR_ID_NONE) {
        return false;
    }
    if (showing_id != s->last_id) {
        s->last_id = showing_id;
        if (s->holds <= PAIR_SLEEP_HOLDS_MAX) {
            s->holds++;
        }
    }
    return s->holds <= PAIR_SLEEP_HOLDS_MAX;
}
