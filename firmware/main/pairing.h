/*
 * Pairing by code (pure C, host-tested in firmware/test/test_pairing.c; ble_link.c applies it, pair_ui.c shows it).
 * LE Secure Connections numeric comparison: the iPhone and the board show the same 6 digits, the owner confirms
 * on both. The translator characteristics need an encrypted, authenticated (MITM) link; board info does not (the
 * app reads it before pairing).
 *
 * Request flow: idle -> showing the code -> accepted / rejected / timed out (PAIR_TIMEOUT_US) -> idle.
 * A second request while one is shown replaces it (the caller rejects the old one).
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#define PAIR_TIMEOUT_US   (30LL * 1000 * 1000)
#define PAIR_TIMEOUT_MS   ((uint32_t)(PAIR_TIMEOUT_US / 1000))
#define PAIR_CONN_NONE    0xFFFF   /* = BLE_HS_CONN_HANDLE_NONE */

typedef enum { PAIR_IDLE = 0, PAIR_SHOWING } pair_phase_t;

/* NUMCMP: compare and answer Đúng / Sai. DISP: the board shows a passkey the phone types in (legacy pairing; iOS
 * uses numeric comparison, kept for completeness): nothing to answer, the view only closes. */
typedef enum { PAIR_KIND_NUMCMP = 0, PAIR_KIND_DISP } pair_kind_t;

typedef enum {
    PAIR_OUT_NONE = 0,   /* nothing to inject (no request, or a DISP request that only closes) */
    PAIR_OUT_ACCEPT,
    PAIR_OUT_REJECT,
    PAIR_OUT_TIMEOUT,    /* reject it (NUMCMP) and close the view */
} pair_outcome_t;

typedef struct {
    pair_phase_t phase;
    pair_kind_t kind;
    uint16_t conn;
    uint32_t passkey;
    int64_t deadline_us;
} pair_t;

static inline void pair_init(pair_t *p)
{
    p->phase = PAIR_IDLE;
    p->kind = PAIR_KIND_NUMCMP;
    p->conn = PAIR_CONN_NONE;
    p->passkey = 0;
    p->deadline_us = 0;
}

/* A passkey action arrived: show it. Returns the link of a NUMCMP request this one replaces, which the caller must
 * reject, or PAIR_CONN_NONE. */
static inline uint16_t pair_begin(pair_t *p, uint16_t conn, pair_kind_t kind, uint32_t passkey, int64_t now_us)
{
    uint16_t replaced = PAIR_CONN_NONE;
    if (p->phase == PAIR_SHOWING && p->conn != conn && p->kind == PAIR_KIND_NUMCMP) {
        replaced = p->conn;
    }
    p->phase = PAIR_SHOWING;
    p->kind = kind;
    p->conn = conn;
    p->passkey = passkey % 1000000u;
    p->deadline_us = now_us + PAIR_TIMEOUT_US;
    return replaced;
}

/* The owner tapped Đúng (yes) or Sai. Late taps (after the deadline) count as a timeout. Ends the request. */
static inline pair_outcome_t pair_answer(pair_t *p, bool yes, int64_t now_us)
{
    if (p->phase != PAIR_SHOWING || p->kind != PAIR_KIND_NUMCMP) {
        return PAIR_OUT_NONE;
    }
    p->phase = PAIR_IDLE;
    if (now_us >= p->deadline_us) {
        return PAIR_OUT_TIMEOUT;
    }
    return yes ? PAIR_OUT_ACCEPT : PAIR_OUT_REJECT;
}

/* Timer check: PAIR_OUT_TIMEOUT ends the request (the caller rejects a NUMCMP one and closes the view). */
static inline pair_outcome_t pair_tick(pair_t *p, int64_t now_us)
{
    if (p->phase != PAIR_SHOWING || now_us < p->deadline_us) {
        return PAIR_OUT_NONE;
    }
    p->phase = PAIR_IDLE;
    return PAIR_OUT_TIMEOUT;
}

/* Pairing finished (either way) or the link went away. True: the view was showing this link's code, close it. */
static inline bool pair_end(pair_t *p, uint16_t conn)
{
    if (p->phase != PAIR_SHOWING || p->conn != conn) {
        return false;
    }
    p->phase = PAIR_IDLE;
    return true;
}

/* The 6 digits as both phones show them: zero-padded, "004213" */
static inline void pair_code_text(uint32_t passkey, char out[7])
{
    snprintf(out, 7, "%06u", (unsigned)(passkey % 1000000u));
}

/* Characteristic access given the link's security. Board info stays open; text, control and audio need the
 * numeric-comparison bond (encrypted AND authenticated). */
typedef enum { PAIR_CHR_INFO = 0, PAIR_CHR_AUDIO, PAIR_CHR_TEXT, PAIR_CHR_CTRL } pair_chr_t;

static inline bool pair_chr_allowed(pair_chr_t chr, bool encrypted, bool authenticated)
{
    if (chr == PAIR_CHR_INFO) {
        return true;
    }
    return encrypted && authenticated;
}

/* The link just encrypted. An unauthenticated key (a Just Works bond from older firmware) must be upgraded:
 * request pairing once per link (true), so the numeric comparison runs. */
static inline bool pair_should_upgrade(bool encrypted, bool authenticated, bool already_requested)
{
    return encrypted && !authenticated && !already_requested;
}
