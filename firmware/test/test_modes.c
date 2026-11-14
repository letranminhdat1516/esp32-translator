// firmware/test/test_modes.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_modes test_modes.c ../main/modes.c && /tmp/test_modes
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
    assert(!m.locked && m.face_until_us == 0);
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(modes_panel(&m, 0) == MODES_PANEL_AUTO);
}

static void pwr1_locks_then_only_shows_the_face(void)
{
    modes_t m = fresh();
    assert(!modes_handle(&m, MODES_EV_PWR_1, 0));         /* lock: no wake */
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_OFF);
    /* PWR x1 on the lock shows the face for 5 s and never unlocks */
    assert(!modes_handle(&m, MODES_EV_PWR_1, 2 * SEC));
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_face_visible(&m, 2 * SEC) && modes_panel(&m, 6 * SEC) == MODES_PANEL_ON);
    assert(modes_panel(&m, 7 * SEC) == MODES_PANEL_OFF);
    assert(!modes_handle(&m, MODES_EV_PWR_1, 8 * SEC) && m.locked);   /* again: the face again */
    assert(modes_face_visible(&m, 8 * SEC));
    /* swipe up on that face: the translator */
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 9 * SEC));
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(modes_panel(&m, 9 * SEC) == MODES_PANEL_AUTO);
}

static void unlock_buttons_when_unlocked_stay_on_the_translator(void)
{
    const modes_event_t evs[] = { MODES_EV_PWR_2, MODES_EV_PWR_3, MODES_EV_BOOT_1 };
    for (int i = 0; i < 3; i++) {
        modes_t m = fresh();
        assert(modes_handle(&m, evs[i], 0));              /* wakes the panel */
        assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR);
    }
}

static void pwr2_pwr3_and_boot_unlock(void)
{
    /* PWR x3 does the same as PWR x2 */
    const modes_event_t evs[] = { MODES_EV_PWR_2, MODES_EV_PWR_3, MODES_EV_BOOT_1 };
    for (int i = 0; i < 3; i++) {
        for (int face = 0; face < 2; face++) {            /* panel dark, or the face up */
            modes_t m = fresh();
            modes_handle(&m, MODES_EV_PWR_1, 0);
            if (face) {
                modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
            }
            assert(modes_handle(&m, evs[i], 2 * SEC));    /* unlocks and wakes */
            assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR);
            assert(!modes_face_visible(&m, 2 * SEC) && m.face_until_us == 0);
        }
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
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
    assert(modes_handle(&m, MODES_EV_TAP_2, 1 * SEC));
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(!modes_face_visible(&m, 1 * SEC));
    modes_handle(&m, MODES_EV_PWR_1, 2 * SEC);              /* lock again: the old face timer is gone */
    assert(modes_panel(&m, 2 * SEC) == MODES_PANEL_OFF);
}

static void swipe_up_on_the_face_unlocks_like_a_double_tap(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);               /* face up */
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 2 * SEC));    /* unlock wakes */
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(!modes_face_visible(&m, 2 * SEC) && m.face_until_us == 0);
    assert(modes_panel(&m, 2 * SEC) == MODES_PANEL_AUTO);
    modes_handle(&m, MODES_EV_PWR_1, 3 * SEC);               /* lock again: the old face timer is gone */
    assert(modes_panel(&m, 3 * SEC) == MODES_PANEL_OFF);
}

static void swipe_up_with_the_face_hidden_does_nothing(void)
{
    /* Pocket guard: a swipe while the panel is dark never unlocks (lock_ui.c does not even post it then) */
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 1 * SEC));
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK && m.face_until_us == 0);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_OFF);
    /* the face timed out: a late swipe does nothing either */
    modes_handle(&m, MODES_EV_TAP_1, 2 * SEC);
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 7 * SEC) && m.locked);
    assert(!modes_face_visible(&m, 7 * SEC) && modes_panel(&m, 7 * SEC) == MODES_PANEL_OFF);
    /* face shown again: now the swipe unlocks */
    modes_handle(&m, MODES_EV_TAP_1, 8 * SEC);
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 9 * SEC) && !m.locked);
}

static void gestures_do_nothing_when_unlocked(void)
{
    modes_t m = fresh();
    assert(!modes_handle(&m, MODES_EV_TAP_1, 0));
    assert(!modes_handle(&m, MODES_EV_TAP_2, 0));
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 0));
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR && m.face_until_us == 0);
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

static void release_and_next_press_in_one_poll(void)
{
    /* Down on entry and a poll sees both edges: the release of that press, then the next press */
    modes_clicks_t c = { 0 };
    uint32_t t = 0;
    assert(run_clicks(&c, "PBR.....", &t) == 2);
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "PBBR.....", &t) == 3);
    c = (modes_clicks_t){ 0 };
    assert(run_clicks(&c, "BB.B.....", &t) == 3);              /* up on entry: press then release, as before */
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
    pwr1_locks_then_only_shows_the_face();
    unlock_buttons_when_unlocked_stay_on_the_translator();
    pwr2_pwr3_and_boot_unlock();
    tap_shows_lock_face_for_five_seconds();
    double_tap_on_lock_screen_unlocks();
    swipe_up_on_the_face_unlocks_like_a_double_tap();
    swipe_up_with_the_face_hidden_does_nothing();
    gestures_do_nothing_when_unlocked();
    counts_single_double_triple();
    release_and_next_press_in_one_poll();
    window_is_450_ms();
    hold_powers_off_once_and_eats_clicks();
    timer_wraparound();
    puts("modes: all tests passed");
    return 0;
}
