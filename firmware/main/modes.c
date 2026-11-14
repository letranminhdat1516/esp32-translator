#include "modes.h"

#include <string.h>

void modes_init(modes_t *m)
{
    memset(m, 0, sizeof(*m));
}

/* Unlocking (PWR x2 / x3, BOOT, tap x2 or swipe up on the lock face) shows the translator */
static bool unlock(modes_t *m)
{
    m->locked = false;
    m->face_until_us = 0;
    return true;
}

bool modes_handle(modes_t *m, modes_event_t ev, int64_t now_us)
{
    switch (ev) {
    case MODES_EV_PWR_1:
        if (m->locked) {
            /* PWR x1 never unlocks: it shows the lock face (swipe up or double tap to unlock) */
            m->face_until_us = now_us + MODES_FACE_US;
            return false;
        }
        m->locked = true;
        m->face_until_us = 0;
        return false;
    case MODES_EV_PWR_2:
    case MODES_EV_PWR_3:
    case MODES_EV_BOOT_1:
        return unlock(m);
    case MODES_EV_TAP_1:
        if (m->locked) {
            m->face_until_us = now_us + MODES_FACE_US;
        }
        return false;
    case MODES_EV_TAP_2:
        return m->locked ? unlock(m) : false;
    case MODES_EV_SWIPE_UP:
        /* Only on the visible face: a swipe on the dark panel (pocket) does nothing here */
        return modes_face_visible(m, now_us) ? unlock(m) : false;
    }
    return false;
}

board_screen_t modes_screen(const modes_t *m)
{
    return m->locked ? SCREEN_LOCK : SCREEN_TRANSLATOR;
}

bool modes_face_visible(const modes_t *m, int64_t now_us)
{
    return m->locked && now_us < m->face_until_us;
}

modes_panel_t modes_panel(const modes_t *m, int64_t now_us)
{
    if (!m->locked) {
        return MODES_PANEL_AUTO;
    }
    return modes_face_visible(m, now_us) ? MODES_PANEL_ON : MODES_PANEL_OFF;
}

static void click_press(modes_clicks_t *c, uint32_t now_ms)
{
    c->down = true;
    c->hold_fired = false;
    c->down_at_ms = now_ms;
}

static void click_release(modes_clicks_t *c, uint32_t now_ms)
{
    if (c->down && !c->hold_fired) {
        c->pending++;
        c->last_release_ms = now_ms;
    }
    c->down = false;
}

int modes_clicks_step(modes_clicks_t *c, bool pressed, bool released, uint32_t now_ms)
{
    if (pressed && released && c->down) {
        /* Already down: this poll saw the release of that press, then the next press */
        click_release(c, now_ms);
        click_press(c, now_ms);
    } else {
        if (pressed) {
            click_press(c, now_ms);
        }
        if (released) {
            click_release(c, now_ms);
        }
    }
    if (c->down && !c->hold_fired && now_ms - c->down_at_ms >= MODES_HOLD_MS) {
        c->hold_fired = true;
        c->pending = 0;
        return MODES_CLICKS_HOLD;
    }
    if (c->pending > 0 && !c->down && now_ms - c->last_release_ms >= MODES_CLICK_WINDOW_MS) {
        int n = c->pending > 3 ? 3 : c->pending;
        c->pending = 0;
        return n;
    }
    return 0;
}
