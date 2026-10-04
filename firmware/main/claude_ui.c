/*
 * Claude companion screen:
 *   top    : "Claude" + link state
 *   middle : project (grey), tool (bold), one-line summary
 *   bottom : Deny / Allow while a permission request is pending (above the translator's Mic button footprint)
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 * A request takes over the screen; once it is answered, cancelled, timed out or the Mac link drops, the
 * previous screen comes back (unless the user switched screens in between).
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

/* Screen a permission request replaced, restored once the request is over; NULL = stay on this screen */
#define RESTORE_DELAY_MS 1200
static lv_obj_t *s_return_scr;
static lv_timer_t *s_restore_timer;

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
    if (s_return_scr && lv_screen_active() == s_scr) {
        lv_screen_load(s_return_scr);
    }
    s_return_scr = NULL;
}

/* LVGL lock held. Goes back to the screen a request replaced, after a short look at the result. */
static void schedule_restore(void)
{
    if (!s_return_scr) {
        return;
    }
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
    set_buttons(false);
    lv_label_set_text(s_project, "");
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_detail, detail);
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
    ui_attach_screen_gestures(s_scr);

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

void claude_ui_present_request(void)
{
    bsp_display_lock((uint32_t)-1);
    lv_obj_t *active = lv_screen_active();
    if (active != s_scr) {
        s_return_scr = active;
        lv_screen_load(s_scr);
    }
    if (s_restore_timer) {
        lv_timer_delete(s_restore_timer);
        s_restore_timer = NULL;
    }
    bsp_display_unlock();
}

bool claude_ui_visible(void)
{
    bsp_display_lock((uint32_t)-1);
    bool v = lv_screen_active() == s_scr;
    bsp_display_unlock();
    return v;
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
        s_pending_id = m->id;
        lv_label_set_text(s_project, project);
        lv_label_set_text(s_title, second ? second : "Permission");
        lv_label_set_text(s_detail, third ? third : "");
        set_buttons(true);
        arm_buttons();
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

void claude_ui_toggle(void)
{
    bsp_display_lock((uint32_t)-1);
    /* The user chose a screen: never auto-return over that choice */
    s_return_scr = NULL;
    if (s_restore_timer) {
        lv_timer_delete(s_restore_timer);
        s_restore_timer = NULL;
    }
    lv_screen_load(lv_screen_active() == s_scr ? ui_translator_screen() : s_scr);
    bsp_display_unlock();
}
