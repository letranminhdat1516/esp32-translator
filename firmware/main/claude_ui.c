/*
 * Claude companion screen:
 *   top    : "Claude · Mac connected", "Claude · N new" (done events of other sessions not seen yet),
 *            or "Claude · Mac not connected"
 *   middle : the focused session (project, "State · elapsed", last assistant line), or the request asked
 *   bottom : Deny / Allow, and Always allow when the Mac offers a rule, while a permission request is pending
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 * Which screen is shown belongs to shell.c: a request takes over the screen there (MODES_EV_URGENT, posted
 * by main.c); once it is answered, cancelled, timed out or the Mac link drops, this file posts
 * MODES_EV_URGENT_DONE after a short look at the result, and the shell restores the mode (or the lock).
 * If the user leaves a shown request (BOOT x1, PWR x1/x2/x3), it stays pending here and on the Mac; the
 * Claude screen shows it again (controls re-armed) until it is answered, cancelled or the Mac drops, and
 * unlocking (PWR x1, lock-screen double tap) brings it back on top (modes.c).
 * A request with no answer or cancel REQUEST_CAP_MS after it arrived is dropped here as if cancelled (the
 * Mac gives up at 90 s and sends a cancel; this covers a lost cancel).
 * Session rows live in picker_ui.c (sessions.c table); this screen shows the focused one.
 */
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"
#include "clock.h"
#include "sessions.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "claude_ui";

static lv_obj_t *s_scr;
static lv_obj_t *s_status;
static lv_obj_t *s_project;
static lv_obj_t *s_title;
static lv_obj_t *s_detail;
static lv_obj_t *s_allow;
static lv_obj_t *s_deny;
static lv_obj_t *s_always;
static volatile uint32_t s_pending_id;   /* 0 = none */
static bool s_always_offered;            /* the pending permission carries a rule */
static bool s_touch_on = true;           /* false while the panel is dark */
static bool s_link;
static question_set_t s_qset;            /* pages of the question shown (or still arriving) */
static claude_question_t s_page;         /* parse buffer: NimBLE host task only, ~0.4 KB off its stack */

/* Answer controls go live only ARM_DELAY_US after a request is shown, a page changes or the panel turns on,
 * and only for a press that began after that: a tap aimed at something else (or at a dark panel) never
 * answers an unread request. */
#define ARM_DELAY_US (700 * 1000)
static int64_t s_armed_at_us;
static int64_t s_press_started_us;

/* How long the result ("Allowed", "Denied", ...) stays up before the shell restores the previous screen */
#define RESTORE_DELAY_MS 1200
static lv_timer_t *s_restore_timer;

/* Board-side cap on a shown request: dropped as "Timed out" if neither an answer nor a cancel came */
#define REQUEST_CAP_MS 100000
static lv_timer_t *s_cap_timer;

/* Elapsed time on the session view: refreshed only while this screen is loaded, skipped while dark */
#define ELAPSED_REFRESH_MS 30000
static lv_timer_t *s_elapsed_timer;

static void arm_buttons(void)
{
    s_armed_at_us = esp_timer_get_time() + ARM_DELAY_US;
}

static void restore_cb(lv_timer_t *t)
{
    s_restore_timer = NULL;
    /* A new request arrived meanwhile: stay, it will restore when it is done */
    if (s_pending_id != 0) {
        return;
    }
    claude_ui_refresh_session_locked();   /* the result goes away: back to the session view */
    shell_post(MODES_EV_URGENT_DONE);
}

/* LVGL lock held. Hands the screen back to the shell after a short look at the result. */
static void schedule_restore(void)
{
    if (s_restore_timer) {
        lv_timer_delete(s_restore_timer);
    }
    s_restore_timer = lv_timer_create(restore_cb, RESTORE_DELAY_MS, NULL);
    lv_timer_set_repeat_count(s_restore_timer, 1);
}

static void set_buttons(bool visible)
{
    lv_obj_set_hidden(s_allow, !visible);
    lv_obj_set_hidden(s_deny, !visible);
    lv_obj_set_hidden(s_always, !(visible && s_always_offered));
}

/* Info or result view: no request pending */
static void show_idle(const char *title, const char *detail)
{
    s_pending_id = 0;
    s_always_offered = false;
    if (s_cap_timer) {
        lv_timer_delete(s_cap_timer);
        s_cap_timer = NULL;
    }
    set_buttons(false);
    question_ui_hide();
    lv_label_set_text(s_project, "");
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_detail, detail);
}

/* LVGL timer, lock held: no answer and no cancel for REQUEST_CAP_MS. Drop it like a cancel. */
static void cap_cb(lv_timer_t *t)
{
    s_cap_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    if (s_pending_id == 0) {
        return;
    }
    ESP_LOGW(TAG, "request %lu: no answer or cancel after %d s, dropping it", (unsigned long)s_pending_id,
             REQUEST_CAP_MS / 1000);
    show_idle("Timed out", "Answer in the terminal.");
    schedule_restore();
}

/* Lock held: a request was just shown */
static void start_cap(void)
{
    if (s_cap_timer) {
        lv_timer_delete(s_cap_timer);
    }
    s_cap_timer = lv_timer_create(cap_cb, REQUEST_CAP_MS, NULL);
    lv_timer_set_repeat_count(s_cap_timer, 1);
}

static void refresh_status(void)
{
    char status[48];
    int badge = picker_ui_badge_locked();
    if (!s_link) {
        snprintf(status, sizeof(status), "Claude · Mac not connected");
    } else if (badge > 0) {
        snprintf(status, sizeof(status), "Claude · %d new", badge);
    } else {
        snprintf(status, sizeof(status), "Claude · Mac connected");
    }
    lv_label_set_text(s_status, status);
}

void claude_ui_refresh_session_locked(void)
{
    if (s_scr == NULL) {
        return;
    }
    refresh_status();
    if (s_pending_id != 0 || s_restore_timer != NULL) {
        return;   /* a request, or its result, is on screen */
    }
    if (!s_link) {
        show_idle("No requests", "Mac not connected.");
        return;
    }
    const claude_session_t *f = picker_ui_focused_locked();
    if (f == NULL) {
        show_idle("No session", "PWR x3 to pick a session.");
        return;
    }
    char title[48];
    int64_t now;
    if (clock_now_unix(&now)) {
        char elapsed[16];
        sessions_format_elapsed(now - f->since, elapsed, sizeof(elapsed));
        snprintf(title, sizeof(title), "%s · %s", sessions_state_label(f->state), elapsed);
    } else {
        snprintf(title, sizeof(title), "%s", sessions_state_label(f->state));
    }
    show_idle(title, f->line);
    lv_label_set_text(s_project, f->project);
}

static void elapsed_cb(lv_timer_t *t)
{
    if (s_touch_on) {
        claude_ui_refresh_session_locked();
    }
}

/* Runs inside lv_screen_load, i.e. in the shell task with the display lock held: the Claude screen came back
 * (PWR x2, a takeover, an unlock). A request left pending meanwhile must be read again before it takes a tap. */
static void on_screen_loaded(lv_event_t *e)
{
    arm_buttons();
    claude_ui_refresh_session_locked();
    if (s_elapsed_timer == NULL) {
        s_elapsed_timer = lv_timer_create(elapsed_cb, ELAPSED_REFRESH_MS, NULL);
    }
}

static void on_screen_unloaded(lv_event_t *e)
{
    if (s_elapsed_timer) {
        lv_timer_delete(s_elapsed_timer);
        s_elapsed_timer = NULL;
    }
}

/* Runs in the LVGL task (lock already held). A tap on the dark panel (the answer buttons are not clickable
 * then, so it lands here) ends a manual screen-off; the controls re-arm when the panel turns on. */
static void on_screen_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

void claude_ui_note_press(void)
{
    s_press_started_us = esp_timer_get_time();
}

bool claude_ui_tap_allowed(void)
{
    /* A tap on a dark panel only wakes it; it must never answer blind */
    if (!s_touch_on) {
        ui_wake_from_tap();
        return false;
    }
    if (s_pending_id == 0) {
        return false;
    }
    /* Pressed before the controls were armed (request just appeared, page changed, panel just woke) */
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before the answer controls were armed");
        return false;
    }
    return true;
}

void claude_ui_rearm(void)
{
    arm_buttons();
}

/* Runs in the LVGL task (lock already held) */
static void on_press(lv_event_t *e)
{
    claude_ui_note_press();
}

/* Runs in the LVGL task (lock already held) */
static void on_answer(lv_event_t *e)
{
    uint8_t decision = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    if (!claude_ui_tap_allowed()) {
        return;
    }
    if (decision == CLAUDE_DECISION_ALWAYS && !s_always_offered) {
        return;
    }
    bool sent = ble_link_send_claude_answer(s_pending_id, decision);
    const char *result = decision == CLAUDE_DECISION_ALLOW    ? "Allowed"
                         : decision == CLAUDE_DECISION_ALWAYS ? "Always allowed"
                                                              : "Denied";
    ESP_LOGI(TAG, "%s for %lu (%s)", result, (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    show_idle(result, sent ? "Claude continues." : "Not sent — answer in the terminal");
    schedule_restore();
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, int x, int y_from_bottom, uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, width, 56);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, y_from_bottom);
    lv_obj_set_style_radius(b, 28, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, on_answer, LV_EVENT_CLICKED, (void *)(uintptr_t)decision);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, int width, int y)
{
    lv_obj_t *l = lv_label_create(s_scr);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

void claude_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_screen_loaded, LV_EVENT_SCREEN_LOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_screen_unloaded, LV_EVENT_SCREEN_UNLOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_screen_tap, LV_EVENT_CLICKED, NULL);

    s_status = make_label(&font_vi_22, 0xc8c8c8, 300, 48);
    s_project = make_label(&font_vi_22, 0x9a9a9a, 360, 86);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 116);
    s_detail = make_label(&font_vi_22, 0xffffff, 380, 166);
    lv_obj_set_height(s_detail, 96);
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_DOTS);

    /* Deny / Allow at y 270..326; Always allow below at y 336..392. Any tap that began before the request
     * was shown (e.g. aimed at the translator's Mic button) is ignored by the arming. */
    s_deny = make_button("Deny", 0x8a1c1c, 150, -80, -140, CLAUDE_DECISION_DENY);
    s_allow = make_button("Allow", 0x1f9d55, 150, 80, -140, CLAUDE_DECISION_ALLOW);
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, CLAUDE_DECISION_ALWAYS);
    question_ui_init(s_scr, &s_qset);   /* after the buttons: the page box covers them while shown */

    show_idle("No requests", "Mac not connected.");
    refresh_status();
    bsp_display_unlock();
}

lv_obj_t *claude_ui_screen(void)
{
    return s_scr;
}

void claude_ui_set_link(bool connected)
{
    bsp_display_lock((uint32_t)-1);
    s_link = connected;
    if (!connected) {
        question_reset(&s_qset);   /* the Mac falls back to the terminal; drop pages still arriving */
    }
    if (!connected && s_pending_id) {
        show_idle("No requests", "Mac disconnected.\nAnswer in the terminal.");
        schedule_restore();
    }
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

bool claude_ui_on_message(const claude_msg_t *m)
{
    /* NimBLE host task only: static, kept off its 4 KB stack */
    static char text[CLAUDE_TEXT_MAX + 1];
    static char detail[CLAUDE_TEXT_MAX + 16];
    snprintf(text, sizeof(text), "%s", m->text);
    /* permission: "project\ntool\nsummary[\nrule]" */
    char *f[4];
    size_t nf = claude_split_lines(text, f, 4);
    bool show = false;

    bsp_display_lock((uint32_t)-1);
    switch (m->kind) {
    case CLAUDE_PERMISSION:
        if (s_restore_timer) {   /* the previous result was still on screen: this request replaces it */
            lv_timer_delete(s_restore_timer);
            s_restore_timer = NULL;
        }
        question_reset(&s_qset);   /* the Mac shows one request at a time: no question is pending now */
        question_ui_hide();
        s_pending_id = m->id;
        s_always_offered = nf >= 4 && f[3][0] != '\0';
        lv_label_set_text(s_project, f[0]);
        lv_label_set_text(s_title, nf >= 2 ? f[1] : "Permission");
        if (s_always_offered) {
            snprintf(detail, sizeof(detail), "%s\nRule: %s", nf >= 3 ? f[2] : "", f[3]);
            lv_label_set_text(s_detail, detail);
        } else {
            lv_label_set_text(s_detail, nf >= 3 ? f[2] : "");
        }
        set_buttons(true);
        arm_buttons();
        start_cap();
        show = true;
        break;
    case CLAUDE_CANCEL:
        if (m->id == s_qset.id) {
            question_reset(&s_qset);   /* also drops a set that was still arriving */
        }
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
            schedule_restore();
        }
        break;
    case CLAUDE_QUESTION:
        if (!claude_parse_question(m, &s_page)) {
            ESP_LOGW(TAG, "ignoring bad question page for %lu", (unsigned long)m->id);
            break;
        }
        if (question_add(&s_qset, m->id, &s_page)) {   /* the last missing page: show page 1 */
            if (s_restore_timer) {
                lv_timer_delete(s_restore_timer);
                s_restore_timer = NULL;
            }
            s_pending_id = m->id;
            s_always_offered = false;
            set_buttons(false);
            question_ui_show();
            arm_buttons();
            start_cap();
            show = true;
        }
        break;
    default:
        /* finished: main.c chimes and toasts, the session view shows the line; sessions: picker_ui.c */
        break;
    }
    bsp_display_unlock();
    return show;
}

/* Runs in the LVGL task (screen timer) when the panel turns on/off */
void claude_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
    picker_ui_set_touch_enabled(on);
    if (s_scr == NULL) {
        return;
    }
    if (on) {
        arm_buttons();   /* the request may have been unread while the panel was dark */
        if (lv_screen_active() == s_scr) {
            claude_ui_refresh_session_locked();   /* elapsed time may be stale */
        }
    }
    /* Not clickable: the tap falls through to the screen object and wakes the panel */
    lv_obj_set_clickable(s_allow, on);
    lv_obj_set_clickable(s_deny, on);
    lv_obj_set_clickable(s_always, on);
}

bool claude_ui_pending(void)
{
    return s_pending_id != 0;
}

/* LVGL task (Send on the last question page): the answers go to the Mac, the result shows briefly */
void claude_ui_question_send_locked(const uint8_t *answer, size_t len)
{
    if (s_pending_id == 0 || s_qset.id != s_pending_id) {   /* only the question shown can be answered */
        ESP_LOGW(TAG, "dropping answers: question %lu is not the pending request", (unsigned long)s_qset.id);
        return;
    }
    bool sent = ble_link_send_claude_input(answer, len);
    ESP_LOGI(TAG, "answers for %lu (%s)", (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    question_reset(&s_qset);
    show_idle(sent ? "Answer sent" : "Not sent", sent ? "Claude continues." : "Answer in the terminal.");
    schedule_restore();
}
