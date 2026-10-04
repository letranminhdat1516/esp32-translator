#include "modes.h"

#include <string.h>

void modes_init(modes_t *m)
{
    memset(m, 0, sizeof(*m));
    m->mode = BOARD_TRANSLATOR;
}

static bool unlock_to(modes_t *m, board_mode_t mode)
{
    m->mode = mode;
    m->locked = false;
    m->urgent = false;
    m->face_until_us = 0;
    return true;
}

bool modes_handle(modes_t *m, modes_event_t ev, int64_t now_us)
{
    switch (ev) {
    case MODES_EV_PWR_1:
        if (m->locked) {
            /* Back to the mode in use; a request shown over the lock stays up until it is done */
            m->locked = false;
            m->face_until_us = 0;
            return true;
        }
        m->locked = true;
        m->urgent = false;   /* the user put the board away: a shown request goes dark (it stays pending) */
        m->face_until_us = 0;
        return false;
    case MODES_EV_PWR_2:
        return unlock_to(m, BOARD_CLAUDE);
    case MODES_EV_PWR_3:
        return unlock_to(m, BOARD_PICKER);
    case MODES_EV_BOOT_1:
        return unlock_to(m, BOARD_TRANSLATOR);
    case MODES_EV_TAP_1:
        if (m->locked && !m->urgent) {
            m->face_until_us = now_us + MODES_FACE_US;
        }
        return false;
    case MODES_EV_TAP_2:
        if (m->locked && !m->urgent) {
            m->locked = false;
            m->face_until_us = 0;
            return true;
        }
        return false;
    case MODES_EV_URGENT:
        m->urgent = true;
        m->face_until_us = 0;
        return true;
    case MODES_EV_URGENT_DONE:
        m->urgent = false;
        return false;
    }
    return false;
}

board_screen_t modes_screen(const modes_t *m)
{
    if (m->urgent) {
        return SCREEN_CLAUDE;
    }
    if (m->locked) {
        return SCREEN_LOCK;
    }
    switch (m->mode) {
    case BOARD_CLAUDE:
        return SCREEN_CLAUDE;
    case BOARD_PICKER:
        return SCREEN_PICKER;
    default:
        return SCREEN_TRANSLATOR;
    }
}

bool modes_face_visible(const modes_t *m, int64_t now_us)
{
    return m->locked && !m->urgent && now_us < m->face_until_us;
}

modes_panel_t modes_panel(const modes_t *m, int64_t now_us)
{
    if (!m->locked) {
        return MODES_PANEL_AUTO;
    }
    if (m->urgent || modes_face_visible(m, now_us)) {
        return MODES_PANEL_ON;
    }
    return MODES_PANEL_OFF;
}

int modes_clicks_step(modes_clicks_t *c, bool pressed, bool released, uint32_t now_ms)
{
    if (pressed) {
        c->down = true;
        c->hold_fired = false;
        c->down_at_ms = now_ms;
    }
    if (released) {
        if (c->down && !c->hold_fired) {
            c->pending++;
            c->last_release_ms = now_ms;
        }
        c->down = false;
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
