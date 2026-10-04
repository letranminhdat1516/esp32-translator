/*
 * iPhone notice screen (Phase 4): one Claude app notification from the iPhone (ANCS, ancs_client.c).
 *   top    : "iPhone · Claude"
 *   middle : title (large), subtitle, message
 *   bottom : Close (board only: the notification stays on the iPhone)
 * phone_ui_show() fills it and posts MODES_EV_NOTICE: the shell loads this screen over any mode or the lock (a
 * Mac request wins, modes.c). It goes away on Close, after NOTICE_SHOW_MS, when the iPhone removes the
 * notification, on any button (PWR x1 only closes it) or a Mac request. Leaving it forgets the notice (labels
 * cleared, ancs_client_close), so nothing is kept.
 * Close is armed like the Claude screen's answers: ARM_DELAY_US after the notice appears, changes or the panel
 * lights, never from a dark panel.
 */
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "phone_ui";

#define NOTICE_SHOW_MS 20000          /* the notice closes itself after this */
#define ARM_DELAY_US   (700 * 1000)

/* All under the display lock */
static lv_obj_t *s_scr;
static lv_obj_t *s_header;
static lv_obj_t *s_title;
static lv_obj_t *s_subtitle;
static lv_obj_t *s_message;
static lv_obj_t *s_close;
static lv_timer_t *s_close_timer;
static bool s_on;                     /* a notice is held (shown, or waiting for the shell to load the screen) */
static uint32_t s_uid;                /* its ANCS uid (0 is a valid uid) */
static bool s_touch_on = true;        /* false while the panel is dark */
static int64_t s_armed_at_us;
static int64_t s_press_started_us;

static void arm(void)
{
    s_armed_at_us = esp_timer_get_time() + ARM_DELAY_US;
}

/* LVGL task: a tap on a dark panel only wakes it; a press that began before the controls were armed is ignored */
static bool tap_armed(void)
{
    if (!s_touch_on) {
        ui_wake_from_tap();
        return false;
    }
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before the controls were armed");
        return false;
    }
    return true;
}

static void close_cb(lv_timer_t *t)
{
    s_close_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    shell_post(MODES_EV_NOTICE_DONE);
}

static void restart_close_timer(uint32_t ms)
{
    if (s_close_timer) {
        lv_timer_delete(s_close_timer);
    }
    s_close_timer = lv_timer_create(close_cb, ms, NULL);
    lv_timer_set_repeat_count(s_close_timer, 1);
}

/* Drops the notice: no timer, no text, the flow forgets it too */
static void forget(void)
{
    if (s_close_timer) {
        lv_timer_delete(s_close_timer);
        s_close_timer = NULL;
    }
    if (s_on) {
        ancs_client_close(s_uid);
        s_on = false;
    }
    lv_label_set_text(s_title, "");
    lv_label_set_text(s_subtitle, "");
    lv_label_set_text(s_message, "");
}

/* Shell task inside lv_screen_load (display lock held) */
static void on_loaded(lv_event_t *e)
{
    arm();
    restart_close_timer(NOTICE_SHOW_MS);
}

static void on_unloaded(lv_event_t *e)
{
    forget();
}

/* LVGL task: a tap on the dark panel lands here (the buttons are not clickable then) */
static void on_screen_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

static void on_press(lv_event_t *e)
{
    s_press_started_us = esp_timer_get_time();
}

static void on_close(lv_event_t *e)
{
    if (tap_armed()) {
        shell_post(MODES_EV_NOTICE_DONE);
    }
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, int width, int y, int height)
{
    lv_obj_t *l = lv_label_create(s_scr);
    lv_obj_set_width(l, width);
    if (height > 0) {
        lv_obj_set_height(l, height);
    }
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    lv_label_set_text(l, "");
    return l;
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, int x, int y_from_bottom, lv_event_cb_t cb,
                             uintptr_t data)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, width, 56);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, y_from_bottom);
    lv_obj_set_style_radius(b, 28, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, (void *)data);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_width(l, width - 24);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_DOTS);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

void phone_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_loaded, LV_EVENT_SCREEN_LOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_unloaded, LV_EVENT_SCREEN_UNLOADED, NULL);
    lv_obj_add_event_cb(s_scr, on_screen_tap, LV_EVENT_CLICKED, NULL);

    s_header = make_label(&font_vi_22, 0xc8c8c8, 300, 48, 0);
    lv_label_set_text(s_header, "iPhone · Claude");
    s_title = make_label(&font_vi_36, 0xffffff, 380, 86, 46);
    s_subtitle = make_label(&font_vi_22, 0x9a9a9a, 360, 134, 28);
    s_message = make_label(&font_vi_22, 0xffffff, 380, 166, 150);   /* y 166..316, above Close */
    lv_label_set_long_mode(s_message, LV_LABEL_LONG_MODE_DOTS);
    s_close = make_button("Close", 0x333333, 150, 0, -74, on_close, 0);
    bsp_display_unlock();
}

lv_obj_t *phone_ui_screen(void)
{
    return s_scr;
}

void phone_ui_show(const ancs_notice_t *n, bool fresh)
{
    bsp_display_lock((uint32_t)-1);
    s_on = true;
    s_uid = n->uid;
    lv_label_set_text(s_title, n->title[0] ? n->title : "Claude");
    lv_label_set_text(s_subtitle, n->subtitle);
    lv_obj_set_hidden(s_subtitle, n->subtitle[0] == '\0');
    lv_label_set_text(s_message, n->message);
    arm();   /* new text under the finger: a tap already on its way must not count */
    if (lv_screen_active() == s_scr) {
        restart_close_timer(NOTICE_SHOW_MS);
    }
    bsp_display_unlock();
    ESP_LOGI(TAG, "notice %lu %s", (unsigned long)n->uid, fresh ? "shown" : "updated");
    shell_post(MODES_EV_NOTICE);   /* takes the screen and wakes the panel (also when locked) */
}

void phone_ui_gone(uint32_t uid)
{
    bsp_display_lock((uint32_t)-1);
    bool mine = s_on && s_uid == uid;
    bool shown = lv_screen_active() == s_scr;
    if (mine && !shown) {
        forget();   /* it never got the screen (a Mac request had it): just forget it */
    }
    bsp_display_unlock();
    if (mine && shown) {
        shell_post(MODES_EV_NOTICE_DONE);
    }
}

/* LVGL task (ui.c screen timer, lock held) when the panel turns on / off */
void phone_ui_set_touch_enabled(bool on)
{
    s_touch_on = on;
    if (s_scr == NULL) {
        return;
    }
    if (on) {
        arm();   /* the notice may have arrived while the panel was dark */
    }
    lv_obj_set_clickable(s_close, on);   /* not clickable: the tap falls through to the screen and wakes */
}
