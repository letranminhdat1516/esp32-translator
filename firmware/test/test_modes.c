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

/* The session picker is opened from the Claude screen (tap on the session title): PWR x3, then that tap */
static void to_picker(modes_t *m, int64_t now)
{
    assert(modes_handle(m, MODES_EV_PWR_3, now));
    assert(modes_handle(m, MODES_EV_OPEN_PICKER, now));
    assert(modes_screen(m) == SCREEN_PICKER);
}

static void starts_unlocked_in_translator(void)
{
    modes_t m = fresh();
    assert(m.mode == BOARD_TRANSLATOR && !m.locked && !m.urgent);
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(modes_panel(&m, 0) == MODES_PANEL_AUTO);
}

static void pwr1_locks_then_only_shows_the_face(void)
{
    modes_t m = fresh();
    assert(modes_handle(&m, MODES_EV_PWR_3, 0));          /* Claude mode, wakes */
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
    /* swipe up on that face: back to the mode in use before locking */
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 9 * SEC));
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    assert(modes_panel(&m, 9 * SEC) == MODES_PANEL_AUTO);
}

static void mode_buttons_switch_when_unlocked(void)
{
    modes_t m = fresh();
    assert(modes_handle(&m, MODES_EV_PWR_3, 0));
    assert(modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_PWR_3, 0);                  /* already Claude: stays (not a toggle) */
    assert(modes_screen(&m) == SCREEN_CLAUDE);
    assert(modes_handle(&m, MODES_EV_OPEN_PICKER, 0));
    assert(modes_screen(&m) == SCREEN_PICKER);
    assert(modes_handle(&m, MODES_EV_PWR_2, 0));          /* PWR x2: translator */
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    modes_handle(&m, MODES_EV_PWR_2, 0);                  /* already translator: stays */
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_handle(&m, MODES_EV_BOOT_1, 0));
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
}

static void mode_buttons_unlock_into_their_mode(void)
{
    const modes_event_t evs[] = { MODES_EV_PWR_2, MODES_EV_PWR_3, MODES_EV_BOOT_1 };
    const board_screen_t want[] = { SCREEN_TRANSLATOR, SCREEN_CLAUDE, SCREEN_TRANSLATOR };
    for (int i = 0; i < 3; i++) {
        for (int face = 0; face < 2; face++) {            /* panel dark, or the face up */
            modes_t m = fresh();
            to_picker(&m, 0);                             /* in use before locking: picker */
            modes_handle(&m, MODES_EV_PWR_1, 0);
            if (face) {
                modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
            }
            assert(modes_handle(&m, evs[i], 2 * SEC));    /* unlocks and wakes */
            assert(!m.locked && modes_screen(&m) == want[i]);
            assert(!modes_face_visible(&m, 2 * SEC) && m.face_until_us == 0);
        }
    }
}

static void open_picker_only_from_the_claude_session_view(void)
{
    modes_t m = fresh();
    assert(!modes_handle(&m, MODES_EV_OPEN_PICKER, 0));               /* translator */
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);                             /* request shown */
    assert(!modes_handle(&m, MODES_EV_OPEN_PICKER, 0) && m.mode == BOARD_CLAUDE);
    modes_handle(&m, MODES_EV_URGENT_DONE, 0);
    modes_handle(&m, MODES_EV_NOTICE, 0);                             /* iPhone notice shown */
    assert(!modes_handle(&m, MODES_EV_OPEN_PICKER, 0) && m.mode == BOARD_CLAUDE);
    modes_handle(&m, MODES_EV_NOTICE_DONE, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);                              /* locked */
    assert(!modes_handle(&m, MODES_EV_OPEN_PICKER, 0) && m.mode == BOARD_CLAUDE && m.locked);
    m = fresh();
    to_picker(&m, 0);
    assert(!modes_handle(&m, MODES_EV_OPEN_PICKER, 0) && modes_screen(&m) == SCREEN_PICKER);
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
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
    assert(modes_handle(&m, MODES_EV_TAP_2, 1 * SEC));
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
    assert(!modes_face_visible(&m, 1 * SEC));
    modes_handle(&m, MODES_EV_PWR_1, 2 * SEC);              /* lock again: the old face timer is gone */
    assert(modes_panel(&m, 2 * SEC) == MODES_PANEL_OFF);
}

static void swipe_up_on_the_face_unlocks_like_a_double_tap(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);               /* face up */
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 2 * SEC));    /* unlock wakes */
    assert(!m.locked && modes_screen(&m) == SCREEN_CLAUDE);
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

static void swipe_up_brings_back_a_left_behind_request(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_PWR_1, 1 * SEC);               /* request goes dark, stays pending */
    modes_handle(&m, MODES_EV_TAP_1, 2 * SEC);
    assert(modes_screen(&m) == SCREEN_LOCK);
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 3 * SEC));
    assert(!m.locked && m.urgent && modes_screen(&m) == SCREEN_CLAUDE);
}

static void swipe_up_is_not_live_over_a_request_a_notice_or_unlocked(void)
{
    modes_t m = fresh();
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 0));         /* unlocked: nothing */
    assert(!m.locked && modes_screen(&m) == SCREEN_TRANSLATOR && m.face_until_us == 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT, 1 * SEC);
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 2 * SEC) && m.locked && m.face_until_us == 0);
    modes_handle(&m, MODES_EV_URGENT_DONE, 3 * SEC);
    modes_handle(&m, MODES_EV_NOTICE, 4 * SEC);
    assert(!modes_handle(&m, MODES_EV_SWIPE_UP, 5 * SEC) && m.locked && m.notice && m.face_until_us == 0);
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

static void pwr1_over_a_request_on_the_lock_shows_the_face(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_PWR_1, 1 * SEC));      /* no unlock: the request goes dark, face up */
    assert(m.locked && !m.urgent && m.pending && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_face_visible(&m, 1 * SEC));
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 2 * SEC));    /* unlock: the request comes back on top */
    assert(!m.locked && m.urgent && modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_URGENT_DONE, 3 * SEC);
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
    to_picker(&m, 0);
    modes_handle(&m, MODES_EV_URGENT_DONE, 0);
    assert(modes_screen(&m) == SCREEN_PICKER && !m.locked);
}

static void left_behind_request_reappears_on_unlock(void)
{
    /* Locking over a shown request: dark, lock face works, the request stays pending */
    modes_t m = fresh();
    to_picker(&m, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_PWR_1, 1 * SEC));
    assert(m.locked && !m.urgent && m.pending && modes_screen(&m) == SCREEN_LOCK);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_OFF);
    /* PWR x1 shows the face; a swipe unlocks straight onto the request (the Claude screen re-arms Allow/Deny) */
    assert(!modes_handle(&m, MODES_EV_PWR_1, 2 * SEC) && m.locked && !m.urgent);
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 2 * SEC));
    assert(!m.locked && m.urgent && modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_URGENT_DONE, 3 * SEC);
    assert(!m.pending && modes_screen(&m) == SCREEN_PICKER);   /* the mode in use comes back */

    /* Same through the lock-screen double tap */
    m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 1 * SEC);
    assert(modes_face_visible(&m, 1 * SEC));
    assert(modes_handle(&m, MODES_EV_TAP_2, 1 * SEC));
    assert(!m.locked && m.urgent && modes_screen(&m) == SCREEN_CLAUDE);

    /* Left with BOOT x1 while unlocked, then lock and unlock: back on the request */
    m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_BOOT_1, 0);
    assert(!m.urgent && m.pending && modes_screen(&m) == SCREEN_TRANSLATOR);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_PWR_1, 1 * SEC);
    assert(modes_handle(&m, MODES_EV_SWIPE_UP, 1 * SEC));
    assert(m.urgent && modes_screen(&m) == SCREEN_CLAUDE);

    /* Answered or dropped while locked: unlocking returns to the mode, nothing pending */
    m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT_DONE, 1 * SEC);
    assert(m.locked && !m.pending && modes_panel(&m, 1 * SEC) == MODES_PANEL_OFF);
    modes_handle(&m, MODES_EV_TAP_1, 2 * SEC);
    modes_handle(&m, MODES_EV_TAP_2, 2 * SEC);
    assert(!m.locked && !m.urgent && modes_screen(&m) == SCREEN_TRANSLATOR);
}

static void urgent_gated_inputs(void)
{
    /* Unlocked, request shown: tap x1 does nothing; PWR x2 / x3 are explicit choices that end the takeover */
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_TAP_1, 1 * SEC));
    assert(m.urgent && m.face_until_us == 0 && modes_screen(&m) == SCREEN_CLAUDE);
    assert(modes_handle(&m, MODES_EV_PWR_2, 1 * SEC));
    assert(!m.urgent && m.pending && m.mode == BOARD_TRANSLATOR && modes_screen(&m) == SCREEN_TRANSLATOR);
    modes_handle(&m, MODES_EV_URGENT, 2 * SEC);
    assert(modes_handle(&m, MODES_EV_PWR_3, 2 * SEC));
    assert(!m.urgent && m.pending && !m.locked && m.mode == BOARD_CLAUDE && modes_screen(&m) == SCREEN_CLAUDE);

    /* Locked, request shown: tap x1 neither shows the face nor hides the request */
    m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_TAP_1, 1 * SEC));
    assert(m.locked && m.urgent && m.face_until_us == 0 && !modes_face_visible(&m, 1 * SEC));
    assert(modes_screen(&m) == SCREEN_CLAUDE && modes_panel(&m, 1 * SEC) == MODES_PANEL_ON);
    /* PWR x3 unlocks into Claude mode (the request is on that screen) */
    assert(modes_handle(&m, MODES_EV_PWR_3, 2 * SEC));
    assert(!m.locked && !m.urgent && m.pending && modes_screen(&m) == SCREEN_CLAUDE);

    /* Locked, request shown: PWR x2 unlocks into the translator */
    m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(modes_handle(&m, MODES_EV_PWR_2, 1 * SEC));
    assert(!m.locked && !m.urgent && m.pending && modes_screen(&m) == SCREEN_TRANSLATOR);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_AUTO);
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

static void pick_goes_to_claude_mode(void)
{
    modes_t m = fresh();
    to_picker(&m, 0);
    assert(modes_report(&m) == 2);
    assert(modes_handle(&m, MODES_EV_PICK, 0));
    assert(modes_screen(&m) == SCREEN_CLAUDE && modes_report(&m) == 1);
}

static void pick_is_ignored_when_locked_or_over_a_request(void)
{
    modes_t m = fresh();
    to_picker(&m, 0);
    modes_handle(&m, MODES_EV_PWR_1, 0);                  /* locked */
    assert(!modes_handle(&m, MODES_EV_PICK, 0));
    assert(m.locked && m.mode == BOARD_PICKER);
    modes_handle(&m, MODES_EV_TAP_1, 0);
    modes_handle(&m, MODES_EV_TAP_2, 0);                  /* unlocked into the picker */
    assert(modes_screen(&m) == SCREEN_PICKER);
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_handle(&m, MODES_EV_PICK, 0));
    assert(m.mode == BOARD_PICKER && m.urgent);
}

static void report_follows_mode_and_lock(void)
{
    modes_t m = fresh();
    assert(modes_report(&m) == 0);
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_report(&m) == 1);
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(modes_report(&m) == 0);                        /* locked: nothing to show */
    modes_handle(&m, MODES_EV_PWR_1, 0);
    assert(modes_report(&m) == 0);                        /* the lock face: still locked */
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(modes_report(&m) == 0);                        /* a request over the lock is not Claude mode */
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_report(&m) == 1);
    modes_handle(&m, MODES_EV_OPEN_PICKER, 0);
    assert(modes_report(&m) == 2);
    modes_handle(&m, MODES_EV_PWR_2, 0);
    assert(modes_report(&m) == 0);
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_BOOT_1, 0);
    assert(modes_report(&m) == 0);
}

static void report_due_covers_link_up_and_mode_changes(void)
{
    modes_t m = fresh();
    int last = MODES_REPORT_UNSENT;                       /* Mac link just came up (or came back) */
    assert(modes_report_due(&last, &m) && last == 0);     /* (a) report even though nothing changed yet */
    assert(!modes_report_due(&last, &m));                 /* nothing new: stay quiet */
    modes_handle(&m, MODES_EV_PWR_3, 0);
    assert(modes_report_due(&last, &m) && last == 1);     /* (b) a mode change */
    assert(!modes_report_due(&last, &m));
    modes_handle(&m, MODES_EV_OPEN_PICKER, 0);
    assert(modes_report_due(&last, &m) && last == 2);
    modes_handle(&m, MODES_EV_PICK, 0);
    assert(modes_report_due(&last, &m) && last == 1);
    modes_handle(&m, MODES_EV_PWR_1, 0);                  /* locked: other */
    assert(modes_report_due(&last, &m) && last == 0);
    last = MODES_REPORT_UNSENT;                           /* the Mac reconnects: report again, even 'other' */
    assert(modes_report_due(&last, &m) && last == 0);
}

static void notice_shows_over_the_mode_and_wakes(void)
{
    modes_t m = fresh();
    assert(modes_handle(&m, MODES_EV_NOTICE, 0));                    /* wakes */
    assert(m.notice && modes_screen(&m) == SCREEN_PHONE);
    assert(modes_panel(&m, 0) == MODES_PANEL_AUTO);                   /* unlocked: ui.c keeps it lit */
    assert(!modes_handle(&m, MODES_EV_NOTICE_DONE, 1 * SEC));
    assert(!m.notice && modes_screen(&m) == SCREEN_TRANSLATOR);
    to_picker(&m, 2 * SEC);
    modes_handle(&m, MODES_EV_NOTICE, 2 * SEC);
    assert(modes_report(&m) == 2);                                    /* the Mac still hears "picker" */
    modes_handle(&m, MODES_EV_NOTICE_DONE, 3 * SEC);
    assert(modes_screen(&m) == SCREEN_PICKER);
}

static void notice_over_the_lock_lights_the_panel(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_TAP_1, 0);                              /* face up */
    assert(modes_handle(&m, MODES_EV_NOTICE, 1 * SEC));
    assert(m.locked && modes_screen(&m) == SCREEN_PHONE);
    assert(modes_panel(&m, 1 * SEC) == MODES_PANEL_ON && !modes_face_visible(&m, 1 * SEC));
    assert(modes_panel(&m, 30 * SEC) == MODES_PANEL_ON);              /* as long as the notice is up */
    modes_handle(&m, MODES_EV_NOTICE_DONE, 31 * SEC);
    assert(m.locked && modes_screen(&m) == SCREEN_LOCK && modes_panel(&m, 31 * SEC) == MODES_PANEL_OFF);
}

static void pwr1_only_closes_the_notice(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_NOTICE, 0);
    assert(!modes_handle(&m, MODES_EV_PWR_1, 1 * SEC));
    assert(!m.notice && m.locked && modes_screen(&m) == SCREEN_LOCK);   /* still locked */
    m = fresh();
    modes_handle(&m, MODES_EV_PWR_3, 0);
    modes_handle(&m, MODES_EV_NOTICE, 0);
    assert(!modes_handle(&m, MODES_EV_PWR_1, 1 * SEC));
    assert(!m.notice && !m.locked && modes_screen(&m) == SCREEN_CLAUDE);   /* still unlocked */
}

static void mode_buttons_close_the_notice(void)
{
    const modes_event_t evs[] = { MODES_EV_PWR_2, MODES_EV_PWR_3, MODES_EV_BOOT_1 };
    const board_screen_t want[] = { SCREEN_TRANSLATOR, SCREEN_CLAUDE, SCREEN_TRANSLATOR };
    for (int i = 0; i < 3; i++) {
        modes_t m = fresh();
        modes_handle(&m, MODES_EV_PWR_1, 0);
        modes_handle(&m, MODES_EV_NOTICE, 0);
        assert(modes_handle(&m, evs[i], 0));
        assert(!m.notice && !m.locked && modes_screen(&m) == want[i]);
    }
}

static void mac_request_wins_over_a_notice(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_NOTICE, 0);
    assert(modes_handle(&m, MODES_EV_URGENT, 0));
    assert(!m.notice && modes_screen(&m) == SCREEN_CLAUDE);           /* the request replaces the notice */
    assert(!modes_handle(&m, MODES_EV_NOTICE, 1 * SEC));              /* not shown over a request */
    assert(!m.notice && modes_screen(&m) == SCREEN_CLAUDE);
    modes_handle(&m, MODES_EV_URGENT_DONE, 2 * SEC);
    assert(modes_screen(&m) == SCREEN_TRANSLATOR);                    /* and not shown afterwards either */
}

static void lock_gestures_and_picks_wait_for_the_notice(void)
{
    modes_t m = fresh();
    modes_handle(&m, MODES_EV_PWR_1, 0);
    modes_handle(&m, MODES_EV_NOTICE, 0);
    assert(!modes_handle(&m, MODES_EV_TAP_1, 1 * SEC) && m.face_until_us == 0);
    assert(!modes_handle(&m, MODES_EV_TAP_2, 1 * SEC) && m.locked && m.notice);
    m = fresh();
    to_picker(&m, 0);
    modes_handle(&m, MODES_EV_NOTICE, 0);
    assert(!modes_handle(&m, MODES_EV_PICK, 0));
    assert(m.mode == BOARD_PICKER && modes_screen(&m) == SCREEN_PHONE);
}

static void notice_waits_while_a_mac_request_is_up(void)
{
    modes_t m = fresh();
    assert(modes_notice_allowed(&m));                     /* nothing urgent: an iPhone notice may show (and chime) */
    assert(modes_handle(&m, MODES_EV_PWR_1, 0) == false); /* locked: still allowed, it lights the panel */
    assert(modes_notice_allowed(&m));
    modes_handle(&m, MODES_EV_URGENT, 0);
    assert(!modes_notice_allowed(&m));                    /* a Mac request has the screen: no notice, no chime */
    modes_handle(&m, MODES_EV_URGENT_DONE, 0);
    assert(modes_notice_allowed(&m));
}

int main(void)
{
    starts_unlocked_in_translator();
    pwr1_locks_then_only_shows_the_face();
    mode_buttons_switch_when_unlocked();
    mode_buttons_unlock_into_their_mode();
    open_picker_only_from_the_claude_session_view();
    tap_shows_lock_face_for_five_seconds();
    double_tap_on_lock_screen_unlocks();
    swipe_up_on_the_face_unlocks_like_a_double_tap();
    swipe_up_with_the_face_hidden_does_nothing();
    swipe_up_brings_back_a_left_behind_request();
    swipe_up_is_not_live_over_a_request_a_notice_or_unlocked();
    taps_do_nothing_when_unlocked();
    urgent_takes_over_then_returns();
    urgent_while_locked_wakes_then_relocks();
    pwr1_over_a_request_on_the_lock_shows_the_face();
    explicit_choices_end_the_takeover();
    urgent_done_without_takeover_is_harmless();
    left_behind_request_reappears_on_unlock();
    urgent_gated_inputs();
    counts_single_double_triple();
    release_and_next_press_in_one_poll();
    window_is_450_ms();
    hold_powers_off_once_and_eats_clicks();
    timer_wraparound();
    pick_goes_to_claude_mode();
    pick_is_ignored_when_locked_or_over_a_request();
    report_follows_mode_and_lock();
    report_due_covers_link_up_and_mode_changes();
    notice_shows_over_the_mode_and_wakes();
    notice_over_the_lock_lights_the_panel();
    pwr1_only_closes_the_notice();
    mode_buttons_close_the_notice();
    mac_request_wins_over_a_notice();
    lock_gestures_and_picks_wait_for_the_notice();
    notice_waits_while_a_mac_request_is_up();
    puts("modes: all tests passed");
    return 0;
}
