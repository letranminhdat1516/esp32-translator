/*
 * Claude companion screen:
 *   top    : "Claude" + link state
 *   middle : project (grey), tool (bold), one-line summary
 *   bottom : Deny / Allow while a permission request is pending (above the translator's Mic button footprint)
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 * Which screen is shown belongs to shell.c: a request takes over the screen there (MODES_EV_URGENT, posted
 * by main.c); once it is answered, cancelled, timed out or the Mac link drops, this file posts
 * MODES_EV_URGENT_DONE after a short look at the result, and the shell restores the mode (or the lock).
 * If the user leaves a shown request (BOOT x1, PWR x1/x2/x3), it stays pending here and on the Mac; the
 * Claude screen shows it again (Allow/Deny re-armed) until it is answered, cancelled or the Mac drops, and
 * unlocking (PWR x1, lock-screen double tap) brings it back on top (modes.c).
 * A request with no answer or cancel REQUEST_CAP_MS after it arrived is dropped here as if cancelled (the
 * Mac gives up at 90 s and sends a cancel; this covers a lost cancel).
 */
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"

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
static volatile uint32_t s_pending_id;   /* 0 = none */
static bool s_touch_on = true;           /* false while the panel is dark */

/* Allow/Deny go live only ARM_DELAY_US after a request is shown or the panel turns on, and only for a press
 * that began after that: a tap aimed at something else (or at a dark panel) never answers an unread request. */
#define ARM_DELAY_US (700 * 1000)
static int64_t s_armed_at_us;
static int64_t s_press_started_us;

/* How long the result ("Allowed", "Denied", ...) stays up before the shell restores the previous screen */
#define RESTORE_DELAY_MS 1200
static lv_timer_t *s_restore_timer;

/* Board-side cap on a shown request: dropped as "Timed out" if neither an answer nor a cancel came */
#define REQUEST_CAP_MS 100000
static lv_timer_t *s_cap_timer;

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
    if (visible) {
        lv_obj_set_hidden(s_allow, false);
        lv_obj_set_hidden(s_deny, false);
    } else {
        lv_obj_set_hidden(s_allow, true);
        lv_obj_set_hidden(s_deny, true);
    }
}

static void show_idle(const char *title, const char *detail)
{
    s_pending_id = 0;
    if (s_cap_timer) {
        lv_timer_delete(s_cap_timer);
        s_cap_timer = NULL;
    }
    set_buttons(false);
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

/* Runs inside lv_screen_load, i.e. in the shell task with the display lock held: the Claude screen came back
 * (PWR x2, a takeover, an unlock). A request left pending meanwhile must be read again before Allow/Deny take
 * a tap. */
static void on_screen_loaded(lv_event_t *e)
{
    arm_buttons();
}

/* Runs in the LVGL task (lock already held). A tap on the dark panel (Allow/Deny are not clickable then, so it
 * lands here) ends a manual screen-off; the buttons re-arm when the panel turns on. */
static void on_screen_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

/* Runs in the LVGL task (lock already held) */
static void on_press(lv_event_t *e)
{
    s_press_started_us = esp_timer_get_time();
}

/* Runs in the LVGL task (lock already held) */
static void on_answer(lv_event_t *e)
{
    uint8_t decision = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    /* A tap on a dark panel only wakes it; it must never answer blind */
    if (s_pending_id == 0 || !s_touch_on) {
        return;
    }
    /* Pressed before the buttons were armed (request just appeared, or panel just woke): ignore */
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before Allow/Deny were armed");
        return;
    }
    bool sent = ble_link_send_claude_answer(s_pending_id, decision);
    ESP_LOGI(TAG, "answer %s for %lu (%s)", decision == 1 ? "allow" : "deny",
             (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    show_idle(decision == 1 ? "Allowed" : "Denied", sent ? "Claude continues." : "Not sent — answer in the terminal");
    schedule_restore();
}

static lv_obj_t *make_button(const char *text, uint32_t color, int x, uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    /* y 270..330: clear of the translator Mic button (y 342..402), still well inside the round panel */
    lv_obj_set_size(b, 150, 60);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, -136);
    lv_obj_set_style_radius(b, 30, 0);
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
    lv_obj_add_event_cb(s_scr, on_screen_tap, LV_EVENT_CLICKED, NULL);

    s_status = make_label(&font_vi_22, 0xc8c8c8, 300, 48);
    s_project = make_label(&font_vi_22, 0x9a9a9a, 360, 86);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 116);
    s_detail = make_label(&font_vi_22, 0xffffff, 380, 166);
    lv_obj_set_height(s_detail, 100);
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_DOTS);

    s_deny = make_button("Deny", 0x8a1c1c, -80, 2);
    s_allow = make_button("Allow", 0x1f9d55, 80, 1);

    lv_label_set_text(s_status, "Claude · Mac not connected");
    show_idle("No requests", "Claude Code permission\nprompts will appear here.");
    bsp_display_unlock();
}

lv_obj_t *claude_ui_screen(void)
{
    return s_scr;
}

void claude_ui_set_link(bool connected)
{
    bsp_display_lock((uint32_t)-1);
    lv_label_set_text(s_status, connected ? "Claude · Mac connected" : "Claude · Mac not connected");
    if (!connected && s_pending_id) {
        show_idle("No requests", "Mac disconnected.\nAnswer in the terminal.");
        schedule_restore();
    }
    bsp_display_unlock();
}

void claude_ui_on_message(const claude_msg_t *m)
{
    /* text: permission "project\ntool\nsummary", finished "project\nline" */
    char text[CLAUDE_TEXT_MAX + 1];
    strncpy(text, m->text, sizeof(text));
    text[CLAUDE_TEXT_MAX] = '\0';
    char *project = text;
    char *second = strchr(project, '\n');
    if (second) {
        *second++ = '\0';
    }
    char *third = second ? strchr(second, '\n') : NULL;
    if (third) {
        *third++ = '\0';
    }

    bsp_display_lock((uint32_t)-1);
    switch (m->kind) {
    case CLAUDE_PERMISSION:
        if (s_restore_timer) {   /* the previous result was still on screen: this request replaces it */
            lv_timer_delete(s_restore_timer);
            s_restore_timer = NULL;
        }
        s_pending_id = m->id;
        lv_label_set_text(s_project, project);
        lv_label_set_text(s_title, second ? second : "Permission");
        lv_label_set_text(s_detail, third ? third : "");
        set_buttons(true);
        arm_buttons();
        if (s_cap_timer) {
            lv_timer_delete(s_cap_timer);
        }
        s_cap_timer = lv_timer_create(cap_cb, REQUEST_CAP_MS, NULL);
        lv_timer_set_repeat_count(s_cap_timer, 1);
        break;
    case CLAUDE_CANCEL:
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
            schedule_restore();
        }
        break;
    case CLAUDE_FINISHED:
        if (s_pending_id == 0) {
            lv_label_set_text(s_project, project);
            lv_label_set_text(s_title, "Claude finished");
            lv_label_set_text(s_detail, second ? second : "");
        }
        break;
    case CLAUDE_TIME:   /* main.c sets the clock; nothing to show */
        break;
    }
    bsp_display_unlock();
}

/* Runs in the LVGL task (screen timer) when the panel turns on/off */
void claude_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
    if (on) {
        arm_buttons();   /* the request may have been unread while the panel was dark */
    }
    if (!s_allow) {
        return;
    }
    /* Not clickable: the tap falls through to the screen object and wakes the panel */
    lv_obj_set_clickable(s_allow, on);
    lv_obj_set_clickable(s_deny, on);
}

bool claude_ui_pending(void)
{
    return s_pending_id != 0;
}
