/*
 * Session picker (tap the top of the Claude screen): up to 6 Claude Code sessions from the Mac, "needs you"
 * first, then the most recent. Row: coloured dot (red needs you, yellow working, green idle, grey ended), project (+ "· new" when
 * its turn ended while another session was focused), short state; the focused one has a white outline.
 * Tap a row: focus it (the Mac is told) and go to the Claude screen.
 * The session table (sessions.c) also feeds the Claude screen. It is written from the NimBLE host task and
 * read from the LVGL task, both only under the display lock (functions named *_locked expect it held).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "lvgl.h"

#include "app.h"
#include "sessions.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "picker_ui";

#define ROW_W 300
#define ROW_H 44

static lv_obj_t *s_scr;
static lv_obj_t *s_list;
static lv_obj_t *s_empty;
static lv_obj_t *s_hint;
static sessions_t s_sessions;
static uint32_t s_row_handle[SESSIONS_SHOWN];
static bool s_touch_on = true;
static bool s_link;

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, uint32_t color, int width)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    return l;
}

/* LVGL task: a tap on the dark panel ends a manual screen-off (PWR hold on USB) */
static void on_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

/* LVGL task, lock held. Never rebuilds the list here: this row is running its own event. */
static void on_row(lv_event_t *e)
{
    if (!s_touch_on) {
        ui_wake_from_tap();   /* a tap on a dark panel only wakes it */
        return;
    }
    uint32_t handle = s_row_handle[(int)(intptr_t)lv_event_get_user_data(e)];
    if (handle == 0) {
        return;
    }
    sessions_set_focus(&s_sessions, handle);
    uint8_t buf[CLAUDE_INPUT_MAX];
    size_t n = claude_encode_focus(handle, buf);
    if (!ble_link_send_claude_input(buf, n)) {
        ESP_LOGW(TAG, "focus %lu not sent (Mac not connected)", (unsigned long)handle);
    }
    claude_ui_refresh_session_locked();
    shell_post(MODES_EV_PICK);
}

static void rebuild_locked(void)
{
    lv_obj_clean(s_list);
    memset(s_row_handle, 0, sizeof(s_row_handle));
    const claude_session_t *rows[SESSIONS_SHOWN];
    int n = sessions_sorted(&s_sessions, rows, SESSIONS_SHOWN);
    lv_label_set_text(s_empty, s_link ? "No sessions yet" : "Mac not connected");
    lv_obj_set_hidden(s_empty, n > 0);
    lv_obj_set_hidden(s_hint, n > 0);
    for (int i = 0; i < n; i++) {
        const claude_session_t *r = rows[i];
        s_row_handle[i] = r->handle;

        lv_obj_t *row = lv_obj_create(s_list);
        lv_obj_set_size(row, ROW_W, ROW_H);
        lv_obj_set_style_radius(row, ROW_H / 2, 0);
        lv_obj_set_style_bg_color(row, lv_color_hex(0x1a1a1a), 0);
        lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
        lv_obj_set_style_border_color(row, lv_color_white(), 0);
        lv_obj_set_style_border_width(row, (r->flags & CLAUDE_SESSION_FOCUSED) ? 2 : 0, 0);
        lv_obj_set_style_pad_all(row, 0, 0);
        lv_obj_set_scrollable(row, false);
        lv_obj_add_event_cb(row, on_row, LV_EVENT_CLICKED, (void *)(intptr_t)i);

        lv_obj_t *dot = lv_obj_create(row);
        lv_obj_set_size(dot, 16, 16);
        lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_border_width(dot, 0, 0);
        lv_obj_set_style_bg_color(dot, lv_color_hex(sessions_state_color(r->state)), 0);
        lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
        lv_obj_set_clickable(dot, false);   /* the tap goes to the row */
        lv_obj_set_scrollable(dot, false);
        lv_obj_align(dot, LV_ALIGN_LEFT_MID, 16, 0);

        char name[CLAUDE_PROJECT_MAX + 16];
        snprintf(name, sizeof(name), "%s%s", r->project, (r->flags & CLAUDE_SESSION_UNSEEN) ? " · new" : "");
        lv_obj_t *label = make_label(row, &font_vi_22, 0xffffff, 150);
        lv_label_set_text(label, name);
        lv_obj_align(label, LV_ALIGN_LEFT_MID, 42, 0);

        lv_obj_t *state = make_label(row, &font_vi_22, 0x9a9a9a, 100);
        lv_obj_set_style_text_align(state, LV_TEXT_ALIGN_RIGHT, 0);
        lv_label_set_text(state, sessions_state_short(r->state));
        lv_obj_align(state, LV_ALIGN_RIGHT_MID, -16, 0);
    }
}

void picker_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_tap, LV_EVENT_CLICKED, NULL);

    lv_obj_t *title = make_label(s_scr, &font_vi_22, 0xc8c8c8, 300);
    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(title, "Claude sessions");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 48);

    /* 6 rows of 44 px with 6 px gaps: y 90..384, full row width fits the round panel there */
    s_list = lv_obj_create(s_scr);
    lv_obj_set_size(s_list, ROW_W + 10, 300);
    lv_obj_align(s_list, LV_ALIGN_TOP_MID, 0, 90);
    lv_obj_set_style_bg_opa(s_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_list, 0, 0);
    lv_obj_set_style_pad_all(s_list, 0, 0);
    lv_obj_set_style_pad_row(s_list, 6, 0);
    lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollable(s_list, false);
    lv_obj_set_clickable(s_list, false);   /* a tap between rows reaches the screen (wakes it) */

    s_empty = make_label(s_scr, &font_vi_36, 0xffffff, 360);
    lv_obj_set_style_text_align(s_empty, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_empty, LV_ALIGN_TOP_MID, 0, 190);
    s_hint = make_label(s_scr, &font_vi_22, 0x9a9a9a, 360);
    lv_label_set_long_mode(s_hint, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_align(s_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(s_hint, "Sessions from your Mac\nwill appear here.");
    lv_obj_align(s_hint, LV_ALIGN_TOP_MID, 0, 250);

    rebuild_locked();
    bsp_display_unlock();
}

lv_obj_t *picker_ui_screen(void)
{
    return s_scr;
}

void picker_ui_on_message(const claude_msg_t *m)
{
    static claude_session_t row;   /* NimBLE host task only: kept off its 6 KB stack */
    if (m->kind == CLAUDE_SESSION && !claude_parse_session(m, &row)) {
        ESP_LOGW(TAG, "ignoring bad session row %lu", (unsigned long)m->id);
        return;
    }
    bsp_display_lock((uint32_t)-1);
    if (m->kind == CLAUDE_SESSION) {
        sessions_upsert(&s_sessions, &row);
    } else if (m->kind == CLAUDE_SESSION_REMOVE) {
        sessions_remove(&s_sessions, m->id);
    } else if (m->kind == CLAUDE_SESSIONS_CLEAR) {
        sessions_clear(&s_sessions);
    }
    rebuild_locked();
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

void picker_ui_set_link(bool connected)
{
    bsp_display_lock((uint32_t)-1);
    s_link = connected;
    if (!connected) {
        sessions_clear(&s_sessions);   /* stale without the Mac; a full sync follows the next activation */
    }
    rebuild_locked();
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

void picker_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
}

const claude_session_t *picker_ui_focused_locked(void)
{
    return sessions_focused(&s_sessions);
}

int picker_ui_badge_locked(void)
{
    return sessions_badge(&s_sessions);
}
