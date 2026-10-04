/*
 * Claude companion screen:
 *   top    : "Claude · Mac connected" / "Claude · via iPhone", "Claude · N new" (done events of other sessions not
 *            seen yet), or "Claude · Mac not connected"; a tap on the top area (status, project, title) on the session
 *            view opens the session picker (MODES_EV_OPEN_PICKER)
 *   middle : the focused session (project, "State · elapsed", last assistant line), or the request asked
 *   bottom : Deny / Allow, and Always allow when the Mac offers a rule, while a permission request is pending;
 *            Deny + why (when the Mac voice link is up): say the reason, Send denies with it (voice_ui.c)
 *            on the session view, Speak (voice command, voice_ui.c) when the Mac voice link is up: disabled with
 *            "Open with cb for voice" when the focused session has no tmux pane the Mac can type into
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 * Which screen is shown belongs to shell.c: a request takes over the screen there (MODES_EV_URGENT, posted
 * by main.c); once it is answered, cancelled, timed out or the Mac link drops, this file posts
 * MODES_EV_URGENT_DONE after a short look at the result, and the shell restores the mode (or the lock).
 * If the user leaves a shown request (BOOT x1, PWR x1/x2/x3), it stays pending here and on the Mac; the
 * Claude screen shows it again (controls re-armed) until it is answered, cancelled or the Mac drops, and
 * unlocking in place (lock-screen swipe up or double tap) brings it back on top (modes.c).
 * A request with no answer or cancel REQUEST_CAP_MS after it arrived is dropped here as if cancelled (the
 * Mac gives up at 90 s and sends a cancel; this covers a lost cancel).
 * Session rows live in picker_ui.c (sessions.c table); this screen shows the focused one.
 */
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
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
static lv_obj_t *s_deny_why;
static lv_obj_t *s_speak;
static lv_obj_t *s_speak_hint;
static lv_obj_t *s_picker_area;          /* invisible tap target over the top labels: session picker */
static uint32_t s_speak_handle;          /* focused session Speak would target; 0 = Speak not usable */
static volatile uint32_t s_pending_id;   /* 0 = none */
static bool s_always_offered;            /* the pending permission carries a rule */
static bool s_touch_on = true;           /* false while the panel is dark */
static bool s_link;
/* The link that is (or was last) up came through the iPhone relay: read at link-up, because ble_link.c has
 * already moved to the new state when it reports the link down */
static bool s_link_relayed;
static question_set_t s_qset;            /* pages of the question shown (or still arriving) */
static claude_question_t s_page;         /* parse buffer: NimBLE host task only, ~0.4 KB off its 6 KB stack */

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

/* Deny / Allow at y 270..326; second row at y 336..392: Deny + why and Always allow side by side (160 wide at
 * x -85 / +85), or whichever of them is offered, centred */
static void set_buttons(bool visible)
{
    bool why = visible && ble_link_voice_ready();
    bool always = visible && s_always_offered;
    lv_obj_set_hidden(s_allow, !visible);
    lv_obj_set_hidden(s_deny, !visible);
    lv_obj_set_hidden(s_always, !always);
    lv_obj_set_hidden(s_deny_why, !why);
    lv_obj_set_width(s_always, why ? 160 : 220);
    lv_obj_align(s_always, LV_ALIGN_BOTTOM_MID, why ? 85 : 0, -74);
    lv_obj_set_width(s_deny_why, always ? 160 : 180);
    lv_obj_align(s_deny_why, LV_ALIGN_BOTTOM_MID, always ? -85 : 0, -74);
}

/* Session view only: Speak for the focused session. Hidden without the Mac voice link or a live session;
 * disabled with a hint when the session has no tmux pane the Mac can type into. */
static void set_speak(const claude_session_t *f)
{
    bool show = f != NULL && s_link && ble_link_voice_ready() && f->state != CLAUDE_STATE_ENDED;
    bool usable = show && (f->flags & CLAUDE_SESSION_VOICE);
    lv_obj_set_hidden(s_speak, !show);
    lv_obj_set_state(s_speak, LV_STATE_DISABLED, !usable);
    lv_obj_set_hidden(s_speak_hint, !(show && !usable));
    s_speak_handle = usable ? f->handle : 0;
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
    set_speak(NULL);
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
    voice_ui_request_gone_locked(s_pending_id);
    question_reset(&s_qset);
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
        snprintf(status, sizeof(status), ble_link_claude_relayed() ? "Claude · via iPhone" : "Claude · Mac connected");
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
        show_idle("No session", "Tap here to pick a session.");
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
    set_speak(f);
}

static void elapsed_cb(lv_timer_t *t)
{
    if (s_touch_on) {
        claude_ui_refresh_session_locked();
    }
}

/* Runs inside lv_screen_load, i.e. in the shell task with the display lock held: the Claude screen came back
 * (PWR x3, a takeover, an unlock). A request left pending meanwhile must be read again before it takes a tap. */
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
    voice_ui_cancel_locked();   /* leaving the Claude screen (BOOT, PWR, lock) drops a capture */
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

bool claude_ui_tap_armed(void)
{
    /* A tap on a dark panel only wakes it; it must never act blind */
    if (!s_touch_on) {
        ui_wake_from_tap();
        return false;
    }
    /* Pressed before the controls were armed (something just appeared, page changed, panel just woke) */
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before the controls were armed");
        return false;
    }
    return true;
}

bool claude_ui_tap_allowed(void)
{
    /* Defence in depth: while the voice overlay is shown no answer control under it may act, whatever the
     * hit-testing does (the overlay's own controls use claude_ui_tap_armed) */
    if (voice_ui_active_locked()) {
        ESP_LOGW(TAG, "ignoring tap on a control under the voice overlay");
        return false;
    }
    return claude_ui_tap_armed() && s_pending_id != 0;
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

/* Runs in the LVGL task (lock already held) */
static void on_speak(lv_event_t *e)
{
    if (voice_ui_active_locked() || !claude_ui_tap_armed() || s_pending_id != 0 || s_speak_handle == 0) {
        return;
    }
    if (!voice_ui_start_locked(CLAUDE_VOICE_FOR_COMMAND, 0, s_speak_handle)) {
        ESP_LOGW(TAG, "voice capture not started");
    }
}

/* Runs in the LVGL task (lock already held): the top area was tapped. Not an answer control, but it must not
 * act blind (dark panel, press before arming), under the voice overlay or while a request (or its result) is
 * shown; modes.c also ignores it unless the Claude mode's own view is up (no takeover, notice or lock). */
static void on_picker_area(lv_event_t *e)
{
    if (voice_ui_active_locked() || !claude_ui_tap_armed() || s_pending_id != 0 || s_restore_timer != NULL) {
        return;
    }
    shell_post(MODES_EV_OPEN_PICKER);
}

/* Runs in the LVGL task (lock already held): say why, Send denies with it */
static void on_deny_why(lv_event_t *e)
{
    if (!claude_ui_tap_allowed() || s_qset.id == s_pending_id) {   /* permission requests only */
        return;
    }
    if (!voice_ui_start_locked(CLAUDE_VOICE_FOR_DENY, 0, s_pending_id)) {
        ESP_LOGW(TAG, "voice capture not started");
    }
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, int x, int y_from_bottom, lv_event_cb_t cb,
                             uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, width, 56);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, y_from_bottom);
    lv_obj_set_style_radius(b, 28, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, (void *)(uintptr_t)decision);
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

    /* Deny / Allow at y 270..326; Always allow / Deny + why below at y 336..392 (set_buttons). Any tap that
     * began before the request was shown (e.g. aimed at the translator's Mic button) is ignored by the arming. */
    s_deny = make_button("Deny", 0x8a1c1c, 150, -80, -140, on_answer, CLAUDE_DECISION_DENY);
    s_allow = make_button("Allow", 0x1f9d55, 150, 80, -140, on_answer, CLAUDE_DECISION_ALLOW);
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, on_answer, CLAUDE_DECISION_ALWAYS);
    s_deny_why = make_button("Deny + why", 0x5a2323, 180, 0, -74, on_deny_why, 0);
    /* Session view: Speak at y 340..396 (where voice_ui.c puts Stop), the hint above it */
    s_speak = make_button("Speak", 0x1e6fd9, 150, 0, -70, on_speak, 0);
    lv_obj_set_style_bg_color(s_speak, lv_color_hex(0x333333), LV_STATE_DISABLED);
    s_speak_hint = make_label(&font_vi_22, 0x9a9a9a, 340, 290);
    /* Session picker: the top area (status, project, title and the first detail lines, y 40..200). Below the
     * question pages and the voice overlay (created after it), so those cover it while shown. */
    s_picker_area = lv_obj_create(s_scr);
    lv_obj_remove_style_all(s_picker_area);
    lv_obj_set_size(s_picker_area, 380, 160);
    lv_obj_align(s_picker_area, LV_ALIGN_TOP_MID, 0, 40);
    lv_obj_set_scrollable(s_picker_area, false);
    lv_obj_add_event_cb(s_picker_area, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(s_picker_area, on_picker_area, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(s_speak_hint, "Open with cb for voice");
    lv_obj_set_hidden(s_speak, true);
    lv_obj_set_hidden(s_speak_hint, true);
    question_ui_init(s_scr, &s_qset);   /* after the buttons: the page box covers them while shown */
    voice_ui_init(s_scr);               /* last: the voice overlay covers question pages too */

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
    if (connected) {
        s_link_relayed = ble_link_claude_relayed();
    } else {
        question_reset(&s_qset);   /* the Mac falls back to the terminal; drop pages still arriving */
    }
    if (!connected && s_pending_id) {
        show_idle("No requests", s_link_relayed ? "iPhone relay disconnected.\nAnswer in the terminal."
                                                : "Mac disconnected.\nAnswer in the terminal.");
        schedule_restore();
    }
    claude_ui_refresh_session_locked();
    bsp_display_unlock();
}

bool claude_ui_on_message(const claude_msg_t *m)
{
    /* NimBLE host task only: static, kept off its 6 KB stack */
    static char text[CLAUDE_TEXT_MAX + 1];
    static char detail[CLAUDE_TEXT_MAX + 16];
    snprintf(text, sizeof(text), "%s", m->text);
    /* permission: "project\ntool\nsummary[\nrule]" */
    char *f[4];
    size_t nf = claude_split_lines(text, f, 4);
    bool show = false;
    bool built_page = false;   /* a request or question page was (re)built: log the stack headroom */

    bsp_display_lock((uint32_t)-1);
    switch (m->kind) {
    case CLAUDE_PERMISSION:
        built_page = true;
        voice_ui_cancel_locked();   /* a request takes over: any capture ends */
        set_speak(NULL);            /* the answer buttons take the bottom */
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
        voice_ui_request_gone_locked(m->id);
        if (m->id == s_qset.id) {
            question_reset(&s_qset);   /* also drops a set that was still arriving */
        }
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
            schedule_restore();
        }
        break;
    case CLAUDE_QUESTION:
        built_page = true;
        if (!claude_parse_question(m, &s_page)) {
            ESP_LOGW(TAG, "ignoring bad question page for %lu", (unsigned long)m->id);
            break;
        }
        if (question_add(&s_qset, m->id, &s_page)) {   /* the last missing page: show page 1 */
            voice_ui_cancel_locked();
            set_speak(NULL);
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
        } else if (m->id == s_pending_id && question_complete(&s_qset)) {
            question_ui_refresh();   /* a shown page was resent: row i must match the label under it */
            arm_buttons();
        }
        break;
    default:
        /* finished: main.c chimes and toasts, the session view shows the line; sessions: picker_ui.c */
        break;
    }
    bsp_display_unlock();
    if (built_page) {
        /* Debug: NimBLE host task stack headroom (bytes never used) after a request / question page */
        ESP_LOGI(TAG, "stack headroom %s: %u bytes", pcTaskGetName(NULL), (unsigned)uxTaskGetStackHighWaterMark(NULL));
    }
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
    lv_obj_set_clickable(s_speak, on);
    lv_obj_set_clickable(s_deny_why, on);
    lv_obj_set_clickable(s_picker_area, on);
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

/* Display lock held (voice_ui.c): the Mac denied the pending request with the spoken reason */
void claude_ui_voice_denied_locked(void)
{
    ESP_LOGI(TAG, "Denied with a spoken reason for %lu", (unsigned long)s_pending_id);
    question_reset(&s_qset);
    show_idle("Denied", "Claude gets your reason.");
    schedule_restore();
}
