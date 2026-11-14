// firmware/test/test_pairing.c — build: cc -Wall -Werror -I../main -o /tmp/test_pairing test_pairing.c && /tmp/test_pairing
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "board_info.h"
#include "pairing.h"

/* This firmware enforces pairing by code (the access rules below), so board info must say so: the app pins a board
 * as secure only at version >= 2 and refuses a secure pin that reports less */
_Static_assert(BOARD_INFO_VERSION >= 2, "board info must report pairing by code (version 2)");

#define SEC 1000000LL
#define MIN (60 * SEC)

static const uint8_t A[PAIR_ADDR_LEN] = { 1, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6 };
static const uint8_t B[PAIR_ADDR_LEN] = { 1, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6 };

static void addr_n(uint8_t out[PAIR_ADDR_LEN], int n)
{
    memset(out, 0, PAIR_ADDR_LEN);
    out[0] = 1;
    out[1] = (uint8_t)n;
    out[2] = (uint8_t)(n >> 8);
}

/* Shows request on conn from addr at now (unlocked, numeric comparison); returns its id */
static uint32_t show(pair_t *p, uint16_t conn, const uint8_t *addr, uint32_t passkey, int64_t now)
{
    assert(pair_begin(p, conn, addr, true, false, passkey, now) == PAIR_BEGIN_SHOW);
    assert(p->phase == PAIR_SHOWING && p->conn == conn);
    return p->id;
}

static void starts_idle(void)
{
    pair_t p;
    pair_init(&p);
    assert(p.phase == PAIR_IDLE);
    assert(p.conn == PAIR_CONN_NONE);
    assert(p.id == PAIR_ID_NONE);
    /* no request: taps, ticks and cancels do nothing */
    assert(pair_answer(&p, 1, PAIR_ID_NONE, true, 0) == PAIR_OUT_NONE);
    assert(pair_answer(&p, 1, 1, true, 10 * SEC) == PAIR_OUT_NONE);
    assert(pair_tick(&p, 100 * SEC) == PAIR_OUT_NONE);
    assert(pair_cancel(&p) == PAIR_OUT_NONE);
    assert(!pair_end(&p, 1));
}

static void accept_and_reject(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 1, A, 482913, 10 * SEC);
    assert(p.passkey == 482913 && id != PAIR_ID_NONE);
    assert(pair_answer(&p, 1, id, true, 15 * SEC) == PAIR_OUT_ACCEPT);
    assert(p.phase == PAIR_IDLE);
    /* a second tap after the answer is ignored */
    assert(pair_answer(&p, 1, id, false, 16 * SEC) == PAIR_OUT_NONE);

    uint32_t id2 = show(&p, 1, A, 7, 30 * SEC);
    assert(id2 != id);   /* every request gets a fresh id */
    assert(pair_answer(&p, 1, id2, false, 31 * SEC + 1) == PAIR_OUT_REJECT);
    assert(p.phase == PAIR_IDLE);
}

static void answer_bound_to_its_request(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 1, A, 111111, 0);
    /* an answer for another link or another (older) request is dropped; the code stays up */
    assert(pair_answer(&p, 2, id, true, 5 * SEC) == PAIR_OUT_NONE);
    assert(pair_answer(&p, 1, id + 1, true, 5 * SEC) == PAIR_OUT_NONE);
    assert(pair_answer(&p, 1, id - 1, true, 5 * SEC) == PAIR_OUT_NONE);
    assert(p.phase == PAIR_SHOWING && p.id == id);

    /* the same link asks again (its old procedure is gone): new id, an answer for the old code no longer counts */
    uint32_t id2 = show(&p, 1, A, 222222, 20 * SEC);
    assert(id2 != id && p.passkey == 222222);
    assert(p.deadline_us == 20 * SEC + PAIR_TIMEOUT_US);
    assert(pair_answer(&p, 1, id, true, 22 * SEC) == PAIR_OUT_NONE);
    assert(pair_answer(&p, 1, id2, true, 22 * SEC) == PAIR_OUT_ACCEPT);
}

static void taps_ignored_first_second(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 1, A, 123456, 10 * SEC);
    /* a tap within 1.0 s of the code appearing was meant for something else */
    assert(pair_answer(&p, 1, id, true, 10 * SEC) == PAIR_OUT_NONE);
    assert(pair_answer(&p, 1, id, true, 10 * SEC + PAIR_ARM_US - 1) == PAIR_OUT_NONE);
    assert(p.phase == PAIR_SHOWING);
    assert(pair_answer(&p, 1, id, true, 10 * SEC + PAIR_ARM_US) == PAIR_OUT_ACCEPT);
}

static void times_out_after_30s(void)
{
    pair_t p;
    pair_init(&p);
    show(&p, 2, A, 123456, 0);
    assert(pair_tick(&p, 29 * SEC) == PAIR_OUT_NONE);
    assert(p.phase == PAIR_SHOWING);
    assert(pair_tick(&p, PAIR_TIMEOUT_US) == PAIR_OUT_TIMEOUT);
    assert(p.phase == PAIR_IDLE && p.id == PAIR_ID_NONE);
    assert(pair_tick(&p, PAIR_TIMEOUT_US + SEC) == PAIR_OUT_NONE);   /* only once */
}

static void late_tap_counts_as_timeout(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 2, A, 123456, 0);
    assert(pair_answer(&p, 2, id, true, 31 * SEC) == PAIR_OUT_TIMEOUT);
    assert(p.phase == PAIR_IDLE);
}

static void only_numeric_comparison(void)
{
    pair_t p;
    pair_init(&p);
    /* passkey entry / OOB: refused before anything else, nothing shown, not even counted */
    assert(pair_begin(&p, 1, A, false, false, 999999, 0) == PAIR_BEGIN_REJECT_METHOD);
    assert(p.phase == PAIR_IDLE);
    show(&p, 1, A, 1, SEC);   /* the rate limit did not see the refused one */
}

static void newcomer_loses(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 1, A, 111111, 0);
    /* another link asks while the first code is up: it is rejected, the shown request is untouched */
    assert(pair_begin(&p, 2, B, true, false, 222222, 5 * SEC) == PAIR_BEGIN_REJECT_BUSY);
    assert(p.phase == PAIR_SHOWING && p.conn == 1 && p.id == id && p.passkey == 111111);
    assert(p.deadline_us == PAIR_TIMEOUT_US);   /* no fresh 30 s for anyone */
    assert(pair_answer(&p, 1, id, true, 6 * SEC) == PAIR_OUT_ACCEPT);
}

static void locked_board_refuses(void)
{
    pair_t p;
    pair_init(&p);
    assert(pair_begin(&p, 1, A, true, true, 482913, 0) == PAIR_BEGIN_REJECT_LOCKED);
    assert(p.phase == PAIR_IDLE && p.id == PAIR_ID_NONE);
    /* locked refusals do not burn the peer's budget: retries while locked, then unlocked a second later: shown */
    for (int i = 1; i <= 2 * PAIR_RATE_MAX; i++) {
        assert(pair_begin(&p, 1, A, true, true, 482913, (int64_t)i * 100 * 1000) == PAIR_BEGIN_REJECT_LOCKED);
    }
    assert(p.peers[0].used == false && p.global_n == 0);
    show(&p, 1, A, 482913, 2 * SEC);
}

static void notices_are_rate_limited(void)
{
    pair_t p;
    pair_init(&p);
    /* "unlock to pair": at most once per 30 s ... */
    assert(PAIR_LOCKED_NOTICE_GAP_US == 30LL * SEC);
    assert(pair_notice_due(&p, PAIR_NOTICE_LOCKED, 0));
    assert(!pair_notice_due(&p, PAIR_NOTICE_LOCKED, SEC));
    assert(!pair_notice_due(&p, PAIR_NOTICE_LOCKED, PAIR_LOCKED_NOTICE_GAP_US - 1));
    assert(pair_notice_due(&p, PAIR_NOTICE_LOCKED, PAIR_LOCKED_NOTICE_GAP_US));
    /* "too many requests": at most once a minute, a history of its own */
    assert(PAIR_RATE_NOTICE_GAP_US == 60LL * SEC);
    assert(pair_notice_due(&p, PAIR_NOTICE_RATE, SEC));
    assert(!pair_notice_due(&p, PAIR_NOTICE_RATE, 30 * SEC));
    assert(!pair_notice_due(&p, PAIR_NOTICE_RATE, SEC + PAIR_RATE_NOTICE_GAP_US - 1));
    assert(pair_notice_due(&p, PAIR_NOTICE_RATE, SEC + PAIR_RATE_NOTICE_GAP_US));
}

static void notice_window_caps(void)
{
    /* ... and at most PAIR_NOTICE_MAX per 10 min, whatever the gap: a device asking every 30 s (locked) or every
     * minute (rate) wakes the panel 5 times, then the refusals are silent until the oldest notice leaves the window */
    pair_notice_t kinds[] = { PAIR_NOTICE_LOCKED, PAIR_NOTICE_RATE };
    int64_t gaps[] = { PAIR_LOCKED_NOTICE_GAP_US, PAIR_RATE_NOTICE_GAP_US };
    for (int k = 0; k < 2; k++) {
        pair_t p;
        pair_init(&p);
        int shown = 0;
        int64_t t = 0;
        for (; t < PAIR_RATE_WINDOW_US; t += gaps[k]) {
            shown += pair_notice_due(&p, kinds[k], t);
        }
        assert(shown == PAIR_NOTICE_MAX);
        assert(!pair_notice_due(&p, kinds[k], PAIR_RATE_WINDOW_US - 1));
        /* the first one (t=0) leaves the window: one more */
        assert(pair_notice_due(&p, kinds[k], PAIR_RATE_WINDOW_US));
        assert(!pair_notice_due(&p, kinds[k], PAIR_RATE_WINDOW_US + gaps[k] - 1));   /* the gap still holds */
        /* a burst right after the cap: silent */
        pair_t r;
        pair_init(&r);
        for (int i = 0; i < PAIR_NOTICE_MAX; i++) {
            assert(pair_notice_due(&r, kinds[k], (int64_t)i * gaps[k]));
        }
        for (int64_t u = PAIR_NOTICE_MAX * gaps[k]; u < PAIR_RATE_WINDOW_US; u += SEC) {
            assert(!pair_notice_due(&r, kinds[k], u));
        }
        /* the other notice's history is untouched */
        assert(p.notice_n[1 - k] == 0);
    }
    /* locked refusals never touch the pairing budget, however many notices they show or suppress */
    pair_t q;
    pair_init(&q);
    for (int i = 0; i < 100; i++) {
        assert(pair_begin(&q, 1, A, true, true, 1, (int64_t)i * SEC) == PAIR_BEGIN_REJECT_LOCKED);
        (void)pair_notice_due(&q, PAIR_NOTICE_LOCKED, (int64_t)i * SEC);
    }
    assert(q.global_n == 0 && q.notice_n[PAIR_NOTICE_LOCKED] == 4);   /* 0, 30, 60, 90 s */
    show(&q, 1, A, 1, 100 * SEC);
}

static void cancel_when_locked_while_showing(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 3, A, 482913, 0);
    assert(pair_cancel(&p) == PAIR_OUT_REJECT);
    assert(p.phase == PAIR_IDLE && p.conn == 3);   /* conn kept: the caller rejects that link */
    assert(pair_answer(&p, 3, id, true, 5 * SEC) == PAIR_OUT_NONE);   /* a tap racing the cancel */
    assert(pair_cancel(&p) == PAIR_OUT_NONE);
}

static void rate_limit_per_peer(void)
{
    pair_t p;
    pair_init(&p);
    /* one attempt per 10 s */
    assert(pair_begin(&p, 1, A, true, false, 1, 0) == PAIR_BEGIN_SHOW);
    pair_end(&p, 1);
    assert(pair_begin(&p, 1, A, true, false, 1, 9 * SEC) == PAIR_BEGIN_REJECT_RATE);
    assert(p.phase == PAIR_IDLE);   /* a refused attempt never touches the screen */
    /* refused attempts are not recorded: 10 s after the first one it works */
    assert(pair_begin(&p, 1, A, true, false, 1, 10 * SEC) == PAIR_BEGIN_SHOW);
    pair_end(&p, 1);
    /* another peer is not affected */
    assert(pair_begin(&p, 2, B, true, false, 1, 10 * SEC + 1) == PAIR_BEGIN_SHOW);
    pair_end(&p, 2);

    /* at most 5 per 10 min: attempts 3..5 at 20, 30, 40 s, the 6th is refused until the first leaves the window */
    for (int i = 2; i < PAIR_RATE_MAX; i++) {
        assert(pair_begin(&p, 1, A, true, false, 1, (int64_t)i * 10 * SEC) == PAIR_BEGIN_SHOW);
        pair_end(&p, 1);
    }
    assert(pair_begin(&p, 1, A, true, false, 1, 50 * SEC) == PAIR_BEGIN_REJECT_RATE);
    assert(pair_begin(&p, 1, A, true, false, 1, 9 * MIN) == PAIR_BEGIN_REJECT_RATE);
    assert(pair_begin(&p, 1, A, true, false, 1, PAIR_RATE_WINDOW_US) == PAIR_BEGIN_SHOW);   /* first one (t=0) is out */
    pair_end(&p, 1);
    assert(pair_begin(&p, 1, A, true, false, 1, PAIR_RATE_WINDOW_US + 10 * SEC) == PAIR_BEGIN_SHOW);   /* t=10 s out */
    pair_end(&p, 1);

    /* busy and locked refusals still count as attempts */
    pair_t q;
    pair_init(&q);
    show(&q, 1, A, 1, 0);
    assert(pair_begin(&q, 2, B, true, false, 1, SEC) == PAIR_BEGIN_REJECT_BUSY);
    assert(pair_begin(&q, 2, B, true, false, 1, 2 * SEC) == PAIR_BEGIN_REJECT_RATE);
    pair_end(&q, 1);
    /* busy counts; locked does not (the board refuses before anything is recorded; its notice is limited apart) */
    assert(pair_begin(&q, 2, B, true, true, 1, 20 * SEC) == PAIR_BEGIN_REJECT_LOCKED);
    assert(pair_begin(&q, 2, B, true, true, 1, 25 * SEC) == PAIR_BEGIN_REJECT_LOCKED);
    assert(pair_begin(&q, 2, B, true, false, 1, 26 * SEC) == PAIR_BEGIN_SHOW);   /* the budget is intact */
}

static void rate_limit_global_and_lru(void)
{
    pair_t p;
    pair_init(&p);
    uint8_t a[PAIR_ADDR_LEN];
    /* an attacker changing its address: each new address passes the per-peer check, the global cap stops it */
    for (int i = 0; i < PAIR_GLOBAL_MAX; i++) {
        addr_n(a, i);
        assert(pair_begin(&p, (uint16_t)i, a, true, false, 1, (int64_t)i * SEC) == PAIR_BEGIN_SHOW);
        pair_end(&p, (uint16_t)i);
    }
    addr_n(a, 100);
    assert(pair_begin(&p, 100, a, true, false, 1, 20 * SEC) == PAIR_BEGIN_REJECT_RATE);
    assert(pair_begin(&p, 100, a, true, false, 1, PAIR_RATE_WINDOW_US) == PAIR_BEGIN_SHOW);   /* the oldest left */
    pair_end(&p, 100);

    /* the table keeps the most recently seen peers: 10 addresses went through 8 slots, so the oldest (0, 1, 2) were
     * dropped; address 100 is still remembered and limited */
    assert(pair_begin(&p, 100, a, true, false, 1, PAIR_RATE_WINDOW_US + SEC) == PAIR_BEGIN_REJECT_RATE);
    int used = 0;
    for (int i = 0; i < PAIR_RATE_PEERS; i++) {
        used += p.peers[i].used;
        uint8_t old[PAIR_ADDR_LEN];
        addr_n(old, 0);
        assert(!p.peers[i].used || memcmp(p.peers[i].addr, old, PAIR_ADDR_LEN) != 0);
    }
    assert(used == PAIR_RATE_PEERS);
}

static void end_closes_only_its_own_link(void)
{
    pair_t p;
    pair_init(&p);
    uint32_t id = show(&p, 1, A, 111111, 0);
    assert(!pair_end(&p, 2));                 /* another link disconnecting */
    assert(p.phase == PAIR_SHOWING);
    assert(pair_end(&p, 1));                  /* this link disconnected / pairing completed */
    assert(p.phase == PAIR_IDLE);
    assert(!pair_end(&p, 1));
    assert(pair_answer(&p, 1, id, true, 5 * SEC) == PAIR_OUT_NONE);   /* a tap racing the close */
}

static void code_text_is_six_digits(void)
{
    char s[7];
    pair_code_text(482913, s);
    assert(strcmp(s, "482913") == 0);
    pair_code_text(4213, s);
    assert(strcmp(s, "004213") == 0);
    pair_code_text(0, s);
    assert(strcmp(s, "000000") == 0);
    pair_code_text(1999999, s);                /* never more than 6 digits */
    assert(strcmp(s, "999999") == 0);
}

static void access_rules(void)
{
    const pair_sec_t none = { false, false, 0, false };
    const pair_sec_t just_works = { true, false, 16, true };
    const pair_sec_t legacy_mitm = { true, true, 16, false };   /* legacy passkey bond: not SC */
    const pair_sec_t short_key = { true, true, 7, true };
    const pair_sec_t sc_mitm = { true, true, 16, true };
    const pair_sec_t not_enc = { false, true, 16, true };       /* not a real state, still no */

    /* board info: always (read before pairing) */
    assert(pair_chr_allowed(PAIR_CHR_INFO, &none));
    pair_chr_t prot[] = { PAIR_CHR_AUDIO, PAIR_CHR_TEXT, PAIR_CHR_CTRL };
    for (unsigned i = 0; i < sizeof(prot) / sizeof(prot[0]); i++) {
        assert(!pair_chr_allowed(prot[i], &none));
        assert(!pair_chr_allowed(prot[i], &just_works));
        assert(!pair_chr_allowed(prot[i], &legacy_mitm));
        assert(!pair_chr_allowed(prot[i], &short_key));
        assert(!pair_chr_allowed(prot[i], &not_enc));
        assert(pair_chr_allowed(prot[i], &sc_mitm));
    }
}

static void upgrade_once_for_weak_link(void)
{
    const pair_sec_t just_works = { true, false, 16, true };
    const pair_sec_t legacy_mitm = { true, true, 16, false };
    const pair_sec_t short_key = { true, true, 7, true };
    const pair_sec_t sc_mitm = { true, true, 16, true };
    const pair_sec_t failed = { false, false, 0, false };
    assert(pair_should_upgrade(&just_works, false));
    assert(pair_should_upgrade(&legacy_mitm, false));   /* authenticated but not Secure Connections */
    assert(pair_should_upgrade(&short_key, false));
    assert(!pair_should_upgrade(&just_works, true));    /* already asked on this link */
    assert(!pair_should_upgrade(&sc_mitm, false));      /* numeric comparison SC bond */
    assert(!pair_should_upgrade(&failed, false));       /* not encrypted (failed): nothing to upgrade */
}

static void sleep_hold_is_counted(void)
{
    pair_sleep_t s;
    pair_sleep_reset(&s);
    assert(!pair_sleep_hold(&s, PAIR_ID_NONE));   /* no code: no hold */
    /* the same request holds for as long as it is up (at most its 30 s) and counts once */
    for (int i = 0; i < 100; i++) {
        assert(pair_sleep_hold(&s, 1));
    }
    assert(s.holds == 1);
    assert(pair_sleep_hold(&s, 2));
    assert(!pair_sleep_hold(&s, PAIR_ID_NONE));
    assert(pair_sleep_hold(&s, 3));
    assert(s.holds == PAIR_SLEEP_HOLDS_MAX);
    /* more remote requests no longer keep the board awake */
    assert(!pair_sleep_hold(&s, 4));
    assert(!pair_sleep_hold(&s, 4));
    assert(!pair_sleep_hold(&s, 5));
    assert(!pair_sleep_hold(&s, 1000));
    /* the app connected (a real session): the budget is back */
    pair_sleep_reset(&s);
    assert(pair_sleep_hold(&s, 1001));
}

int main(void)
{
    starts_idle();
    accept_and_reject();
    answer_bound_to_its_request();
    taps_ignored_first_second();
    times_out_after_30s();
    late_tap_counts_as_timeout();
    only_numeric_comparison();
    newcomer_loses();
    locked_board_refuses();
    notices_are_rate_limited();
    notice_window_caps();
    cancel_when_locked_while_showing();
    rate_limit_per_peer();
    rate_limit_global_and_lru();
    end_closes_only_its_own_link();
    code_text_is_six_digits();
    access_rules();
    upgrade_once_for_weak_link();
    sleep_hold_is_counted();
    puts("test_pairing: all passed");
    return 0;
}
