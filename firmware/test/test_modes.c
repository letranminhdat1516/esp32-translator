// firmware/test/test_modes.c — build: cc -Wall -Werror -I../main -o /tmp/test_modes test_modes.c ../main/modes.c && /tmp/test_modes
#include <assert.h>
#include <stdio.h>
#include "modes.h"

#define SEC 1000000LL

static modes_t fresh(void)
{
    modes_t m;
    modes_init(&m);
    return m;
}

static void starts_unlocked_in_translator(void)
{
    modes_t m = fresh();
    assert(m.mode == BOARD_TRANSLATOR && !m.locked && !m.urgent);
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(modes_panel(&m, 0) == MODES_PANEL_AUTO);
}

static void pwr1_locks_and_unlocks_to_previous_mode(void)
{
    modes_t m = fresh();
    assert(modes_handle(&m, MODES_EV_PWR_2, 0));          /* Claude mode, wakes */
    assert(!modes_handle(&m, MODES_EV_PWR_1, 0));         /* lock: no wake */
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_OFF);
    assert(modes_handle(&m, MODES_EV_PWR_1, 2 * SEC));    /* unlock wakes */
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    assert(modes_panel(&m, 2 * SEC) == MODES_PANEL_AUTO);
}

static void mode_buttons_switch_when_unlocked(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_2, 0);
    assert(modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_PWR_2, 0);                  /* already Claude: stays (not a toggle) */
    assert(modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_screen(&m) == SCREEN_PICKER);
    assert(modes_handle(&m, MODES_EV_BOOT_1, 0));
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
}

static void mode_buttons_unlock_into_their_mode(void)
{
    const modes_event_t evs[] = { MODES_EV_PWR_2, MODES_EV_PWR_3, MODES_EV_BOOT_1 };
    const board_screen_t want[] = { SCREEN_CLAUDE, SCREEN_PICKER, SCREEN_TRANSLATOR };
    for (int i = 0; i < 3; i++) {
        modes_t m = fresh();
        modes_handle(&m, MODES_EV_PWR_3, 0);              /* in use before locking: picker */
        modes_handle(&m, MODES_EV_PWR_1, 0);
        assert(modes_handle(&m, evs[i], 0));
        assert(!m.locked && modes_screen(&m) == want[i]);
    }
}

static void tap_shows_lock_face_for_five_seconds(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(!modes_face_visible(&m, 10 * SEC));
    assert(!modes_handle(&m, MODES_EV_TAP_1, 10 * SEC));   /* face is not a wake: the policy turns it on */
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_face_visible(&m, 10 * SEC));
    assert(modes_panel(&m, 14 * SEC + 999999) == MODES_PANEL_ON);
    assert(modes_panel(&m, 15 * SEC) == MODES_PANEL_OFF);
    assert(!modes_face_visible(&m, 15 * SEC));
    modes_handle(&m, MODES_EV_TAP_1, 20 * SEC);             /* another tap restarts it */
    assert(modes_panel(&m, 24 * SEC) == MODES_PANEL_ON);
}

static void double_tap_on_lock_screen_unlocks(void)
{
    /* LVGL sends SINGLE then DOUBLE for one double tap: the face flashes, then the board unlocks */
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_2, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
    assert(modes_handle(&m, MODES_EV_TAP_2, 1 * SEC));
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    assert(!modes_face_visible(&m, 1 * SEC));
    modes_handle(&m, MODES_EV_PWR_1, 2 * SEC);              /* lock again: the old face timer is gone */
    assert(modes_panel(&m, 2 * SEC) == MODES_PANEL_OFF);
}

static void taps_do_nothing_when_unlocked(void)
{
    modes_t m = fresh();
    assert(!modes_handle(&m, MODES_EV_TAP_1, 0));
    assert(!modes_handle(&m, MODES_EV_TAP_2, 0));
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR && m.face_until_us == 0);
}

static void urgent_takes_over_then_returns(void)
{
    modes_t m = fresh();
    assert(modes_handle(&m, MODES_EV_URGENT, 0));
    assert(modes_screen(&m) == SCREEN_CLAUDE);
    assert(!modes_handle(&m, MODES_EV_URGENT_DONE, 0));
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
}

static void urgent_while_locked_wakes_then_relocks(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(modes_handle(&m, MODES_EV_URGENT, 1 * SEC));
    assert(m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    assert(modes_panel(&m, 60 * SEC) == MODES_PANEL_ON);     /* stays lit while the request is shown */
    modes_handle(&m, MODES_EV_TAP_2, 2 * SEC);               /* lock gestures are not live over a request */
    assert(m.locked);
    modes_handle(&m, MODES_EV_URGENT_DONE, 61 * SEC);
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_panel(&m, 61 * SEC) == MODES_PANEL_OFF);
}

static void unlocking_over_a_request_keeps_it_shown(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(modes_handle(&m, MODES_EV_PWR_1, 0));             /* unlock: request still on screen */
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_URGENT_DONE, 0);
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);           /* back to the mode in use before locking */
}

static void explicit_choices_end_the_takeover(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_BOOT_1, 0);                    /* user picked the translator */
    assert(!m.urgent && modes_screen(&m) == SCREEN_TRANSLATOR);

    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);                     /* user locked the board */
    assert(m.locked && !m.urgent && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_panel(&m, 0) == MODES_PANEL_OFF);
}

static void urgent_done_without_takeover_is_harmless(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_URGENT_DONE, 0);
    assert(modes_screen(&m) == SCREEN_PICKER && !m.locked);
}

/* Feeds a press/release script: each entry is one 100 ms poll. Returns the first non-zero result. */
static int run_clicks(modes_clicks_t *c, const char *polls, uint32_t *t)
{
    for (const char *p = polls; *p; p++, *t += 100) {
        int r = modes_clicks_step(c, *p == 'P' || *p == 'B', *p == 'R' || *p == 'B', *t);
        if (r) {
            return r;
        }
    }
    return 0;
}

static void counts_single_double_triple(void)
{
    /* P = pressed, R = released, B = both in one poll, . = nothing */
    modes_clicks_t c = { 0 };
    uint32_t t = 1000;
    assert(run_clicks(&c, "PR.....", &t) == 1);
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "PR..PR.....", &t) == 2);
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "BB.B.....", &t) == 3);
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "BBBBB.....", &t) == 3);             /* 5 quick presses still mean x3 */
}

static void window_is_450_ms(void)
{
    modes_clicks_t c = { 0 };
    uint32_t t = 0;
    assert(run_clicks(&c, "PR....PR.....", &t) == 2);        /* 400 ms gap: same series */
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "PR.....", &t) == 1);              /* 500 ms of quiet ends a series */
    assert(c.pending == 0);
    assert(run_clicks(&c, "PR.....", &t) == 1);              /* the next press starts a new one */
}

static void hold_powers_off_once_and_eats_clicks(void)
{
    modes_clicks_t c = { 0 };
    uint32_t t = 0;
    /* a click, then press and hold: the hold wins and the earlier click is dropped */
    assert(run_clicks(&c, "B.P................................", &t) == MODES_CLICKS_HOLD);
    assert(run_clicks(&c, "......R......", &t) == 0);        /* release after the hold: no click */
    assert(c.pending == 0);
}

static void timer_wraparound(void)
{
    modes_clicks_t c = { 0 };
    uint32_t t = 0xFFFFFF00u;
    assert(run_clicks(&c, "PR.....", &t) == 1);
}

int main(void)
{
    starts_unlocked_in_translator();
    pwr1_locks_and_unlocks_to_previous_mode();
    mode_buttons_switch_when_unlocked();
    mode_buttons_unlock_into_their_mode();
    tap_shows_lock_face_for_five_seconds();
    double_tap_on_lock_screen_unlocks();
    taps_do_nothing_when_unlocked();
    urgent_takes_over_then_returns();
    urgent_while_locked_wakes_then_relocks();
    unlocking_over_a_request_keeps_it_shown();
    explicit_choices_end_the_takeover();
    urgent_done_without_takeover_is_harmless();
    counts_single_double_triple();
    window_is_450_ms();
    hold_powers_off_once_and_eats_clicks();
    timer_wraparound();
    puts("modes: all tests passed");
    return 0;
}
