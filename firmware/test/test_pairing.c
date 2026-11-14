// firmware/test/test_pairing.c — build: cc -Wall -Werror -I../main -o /tmp/test_pairing test_pairing.c && /tmp/test_pairing
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "pairing.h"

#define SEC 1000000LL

static void starts_idle(void)
{
    pair_t p;
    pair_init(&p);
    assert(p.phase == PAIR_IDLE);
    assert(p.conn == PAIR_CONN_NONE);
    /* no request: taps and ticks do nothing */
    assert(pair_answer(&p, true, 0) == PAIR_OUT_NONE);
    assert(pair_tick(&p, 100 * SEC) == PAIR_OUT_NONE);
    assert(!pair_end(&p, 1));
}

static void accept_and_reject(void)
{
    pair_t p;
    pair_init(&p);
    assert(pair_begin(&p, 1, PAIR_KIND_NUMCMP, 482913, 10 * SEC) == PAIR_CONN_NONE);
    assert(p.phase == PAIR_SHOWING && p.conn == 1 && p.passkey == 482913);
    assert(pair_answer(&p, true, 15 * SEC) == PAIR_OUT_ACCEPT);
    assert(p.phase == PAIR_IDLE);
    /* a second tap after the answer is ignored */
    assert(pair_answer(&p, false, 16 * SEC) == PAIR_OUT_NONE);

    pair_begin(&p, 1, PAIR_KIND_NUMCMP, 7, 20 * SEC);
    assert(pair_answer(&p, false, 21 * SEC) == PAIR_OUT_REJECT);
    assert(p.phase == PAIR_IDLE);
}

static void times_out_after_30s(void)
{
    pair_t p;
    pair_init(&p);
    pair_begin(&p, 2, PAIR_KIND_NUMCMP, 123456, 0);
    assert(pair_tick(&p, 29 * SEC) == PAIR_OUT_NONE);
    assert(p.phase == PAIR_SHOWING);
    assert(pair_tick(&p, PAIR_TIMEOUT_US) == PAIR_OUT_TIMEOUT);
    assert(p.phase == PAIR_IDLE);
    assert(pair_tick(&p, PAIR_TIMEOUT_US + SEC) == PAIR_OUT_NONE);   /* only once */
}

static void late_tap_counts_as_timeout(void)
{
    pair_t p;
    pair_init(&p);
    pair_begin(&p, 2, PAIR_KIND_NUMCMP, 123456, 0);
    assert(pair_answer(&p, true, 31 * SEC) == PAIR_OUT_TIMEOUT);
    assert(p.phase == PAIR_IDLE);
}

static void disp_has_nothing_to_answer(void)
{
    pair_t p;
    pair_init(&p);
    pair_begin(&p, 1, PAIR_KIND_DISP, 999999, 0);
    assert(pair_answer(&p, true, SEC) == PAIR_OUT_NONE);
    assert(p.phase == PAIR_SHOWING);       /* stays up until pairing ends or the timeout */
    assert(pair_end(&p, 1));
    assert(p.phase == PAIR_IDLE);
}

static void new_request_replaces_old(void)
{
    pair_t p;
    pair_init(&p);
    pair_begin(&p, 1, PAIR_KIND_NUMCMP, 111111, 0);
    /* another link asks: the first one must be rejected by the caller */
    assert(pair_begin(&p, 2, PAIR_KIND_NUMCMP, 222222, 5 * SEC) == 1);
    assert(p.conn == 2 && p.passkey == 222222);
    assert(p.deadline_us == 5 * SEC + PAIR_TIMEOUT_US);   /* fresh 30 s */
    /* the same link asking again: nothing to reject */
    assert(pair_begin(&p, 2, PAIR_KIND_NUMCMP, 333333, 6 * SEC) == PAIR_CONN_NONE);
    /* a DISP request being replaced has nothing to reject either */
    pair_begin(&p, 1, PAIR_KIND_DISP, 1, 7 * SEC);
    assert(pair_begin(&p, 2, PAIR_KIND_NUMCMP, 2, 8 * SEC) == PAIR_CONN_NONE);
}

static void end_closes_only_its_own_link(void)
{
    pair_t p;
    pair_init(&p);
    pair_begin(&p, 1, PAIR_KIND_NUMCMP, 111111, 0);
    assert(!pair_end(&p, 2));                 /* another link disconnecting */
    assert(p.phase == PAIR_SHOWING);
    assert(pair_end(&p, 1));                  /* this link disconnected / pairing completed */
    assert(p.phase == PAIR_IDLE);
    assert(!pair_end(&p, 1));
    assert(pair_answer(&p, true, SEC) == PAIR_OUT_NONE);   /* a tap racing the close */
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
    /* board info: always (read before pairing) */
    assert(pair_chr_allowed(PAIR_CHR_INFO, false, false));
    pair_chr_t prot[] = { PAIR_CHR_AUDIO, PAIR_CHR_TEXT, PAIR_CHR_CTRL };
    for (unsigned i = 0; i < sizeof(prot) / sizeof(prot[0]); i++) {
        assert(!pair_chr_allowed(prot[i], false, false));
        assert(!pair_chr_allowed(prot[i], true, false));   /* Just Works bond: not enough */
        assert(!pair_chr_allowed(prot[i], false, true));   /* not a real state, still no */
        assert(pair_chr_allowed(prot[i], true, true));
    }
}

static void upgrade_once_for_unauthenticated_link(void)
{
    assert(pair_should_upgrade(true, false, false));
    assert(!pair_should_upgrade(true, false, true));    /* already asked on this link */
    assert(!pair_should_upgrade(true, true, false));    /* numeric comparison bond */
    assert(!pair_should_upgrade(false, false, false));  /* not encrypted (failed): nothing to upgrade */
}

int main(void)
{
    starts_idle();
    accept_and_reject();
    times_out_after_30s();
    late_tap_counts_as_timeout();
    disp_has_nothing_to_answer();
    new_request_replaces_old();
    end_closes_only_its_own_link();
    code_text_is_six_digits();
    access_rules();
    upgrade_once_for_unauthenticated_link();
    puts("test_pairing: all passed");
    return 0;
}
