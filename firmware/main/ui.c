/*
 * Round 466x466 screen:
 *   top    : status line (connection / listening)
 *   middle : live English subtitles for the other person (streamed by the app while you speak)
 *   bottom : board mic on/off button
 */
#include <stdlib.h>

#include "bsp/esp-bsp.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

#define COLOR_IDLE  0x2a2a2a
#define COLOR_EN    0x1e6fd9
#define COLOR_MUTED 0xc8c8c8

static lv_obj_t *s_status;
static lv_obj_t *s_ring;
static int s_level = -1;
static lv_obj_t *s_text_box;
static lv_obj_t *s_text;
static lv_obj_t *s_btn_mic;
static lv_obj_t *s_btn_label;
static bool s_connected;

/* The AMOLED draws power per lit pixel and per brightness step: turn it off when nobody needs it */
#define SCREEN_OFF_AFTER_MS 30000

static volatile int64_t s_last_activity_us;
static bool s_screen_on = true;
/* Double-tap off: stays dark (ignores taps and subtitles) until the next double-tap */
static volatile bool s_manual_off;
static lv_obj_t *s_translator_scr;
/* Power-off / sleep message on screen: the screen timer leaves the panel alone from then on */
static volatile bool s_shutting_down;

static void lock(void)
{
    bsp_display_lock((uint32_t)-1);
}

static void unlock(void)
{
    bsp_display_unlock();
}

static void on_button(lv_event_t *e)
{
    /* Only queue the request: we are inside the LVGL task, so don't touch the UI here */
    app_request_recording(app_get_recording() == REC_NONE ? REC_EN : REC_NONE);
}

static void refresh_status(rec_lang_t lang);

static void set_screen(bool on)
{
    if (on == s_screen_on) {
        return;
    }
    s_screen_on = on;
    claude_ui_set_touch_enabled(on);
    phone_ui_set_touch_enabled(on);
    bsp_display_brightness_set(on ? 100 : 0);
    /* While dark, a tap only wakes the screen; it must not toggle the mic */
    lv_obj_set_clickable(s_btn_mic, on);
}

/* Runs inside the LVGL task every 250 ms */
static void screen_timer_cb(lv_timer_t *t)
{
    if (s_shutting_down) {
        return;
    }
    /* Locked: the lock policy alone decides (activity, subtitles and toasts never light a locked panel) */
    int64_t now = esp_timer_get_time();
    modes_t m;
    shell_snapshot(&m);
    lock_ui_set_face(modes_face_visible(&m, now));
    modes_panel_t panel = modes_panel(&m, now);
    if (panel != MODES_PANEL_AUTO) {
        set_screen(panel == MODES_PANEL_ON);
        return;
    }
    if (s_manual_off) {
        set_screen(false);
        return;
    }
    if (voice_ui_active_locked()) {
        set_screen(true);   /* a voice capture, its confirmation or its result is on screen */
        return;
    }
    if (modes_screen(&m) == SCREEN_PHONE) {
        set_screen(true);   /* an iPhone notice is up (it closes itself after 20 s, or 60 s with actions) */
        return;
    }
    if (claude_ui_pending() && modes_screen(&m) == SCREEN_CLAUDE) {
        set_screen(true);   /* keep Allow/Deny visible while a request is pending (on the Claude screen only) */
        return;
    }
    int64_t idle_ms = (now - s_last_activity_us) / 1000;
    uint32_t touch_idle_ms = lv_display_get_inactive_time(NULL);
    if (touch_idle_ms < idle_ms) {
        idle_ms = touch_idle_ms;
    }
    set_screen(idle_ms < SCREEN_OFF_AFTER_MS);
}

/* Translator only: double-tap anywhere outside the mic button toggles the screen */
static void on_double_tap(lv_event_t *e)
{
    s_manual_off = s_screen_on;
    if (!s_manual_off) {
        s_last_activity_us = esp_timer_get_time();
    }
    set_screen(!s_manual_off);
}

lv_obj_t *ui_translator_screen(void)
{
    return s_translator_scr;
}

void ui_set_level(int percent)
{
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }
    /* Redrawing the ring touches the whole screen: skip small changes */
    if (s_level >= 0 && (percent == 0) == (s_level == 0) && abs(percent - s_level) < 8) {
        return;
    }
    s_level = percent;
    lock();
    lv_obj_set_hidden(s_ring, percent == 0);
    if (percent != 0) {
        /* Faint speech: thin and dim; clear speech: thick and bright */
        lv_obj_set_style_arc_width(s_ring, 3 + percent / 12, LV_PART_INDICATOR);
        lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(60 + percent * 195 / 100), LV_PART_INDICATOR);
    }
    unlock();
}

void ui_mark_activity(void)
{
    s_last_activity_us = esp_timer_get_time();
}

void ui_force_screen_on(void)
{
    s_manual_off = false;
    ui_mark_activity();
}

void ui_wake_from_tap(void)
{
    /* LVGL task: only flags, the 250 ms screen timer turns the panel on (and re-arms Allow/Deny) */
    if (s_manual_off) {
        s_manual_off = false;
        ui_mark_activity();
    }
}

bool ui_shutting_down(void)
{
    return s_shutting_down;
}

void ui_set_manual_screen_off(bool off)
{
    /* The 250 ms screen timer applies the flag */
    s_manual_off = off;
    if (!off) {
        ui_mark_activity();
    }
}

static void toast_done_cb(lv_timer_t *t)
{
    refresh_status(app_get_recording());
}

void ui_toast(const char *utf8, uint32_t ms)
{
    s_manual_off = false;
    ui_mark_activity();
    lock();
    lv_label_set_text(s_status, utf8);
    lv_timer_t *t = lv_timer_create(toast_done_cb, ms, NULL);
    lv_timer_set_repeat_count(t, 1);
    unlock();
}

void ui_prepare_power_off(void)
{
    lock();
    s_shutting_down = true;
    lv_screen_load(s_translator_scr);   /* the message lives there, whatever mode or lock was shown */
    s_manual_off = false;
    set_screen(true);
    lv_label_set_text(s_status, "Powering off");
    lv_label_set_text(s_text, "Press the PWR button\nto turn on");
    unlock();
    vTaskDelay(pdMS_TO_TICKS(1500));
    lock();
    bsp_display_brightness_set(0);
    unlock();
}

void ui_prepare_sleep(void)
{
    lock();
    s_shutting_down = true;
    lv_screen_load(s_translator_scr);
    lv_label_set_text(s_status, "Sleeping");
    lv_label_set_text(s_text, "Touch the screen\nto wake up");
    unlock();
    vTaskDelay(pdMS_TO_TICKS(2500));
    lock();
    bsp_display_brightness_set(0);
    unlock();
}

void ui_init(void)
{
    s_last_activity_us = esp_timer_get_time();
    lock();
    lv_obj_t *scr = lv_screen_active();
    s_translator_scr = scr;
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_set_style_text_color(scr, lv_color_white(), 0);

    s_status = lv_label_create(scr);
    lv_obj_set_width(s_status, 300);
    lv_obj_set_style_text_font(s_status, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(COLOR_MUTED), 0);
    lv_obj_set_style_text_align(s_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(s_status, LV_ALIGN_TOP_MID, 0, 48);

    /* Level ring: tells the speaker the board hears them (and to come closer when it is faint) */
    s_ring = lv_arc_create(scr);
    lv_obj_set_size(s_ring, 462, 462);
    lv_obj_center(s_ring);
    lv_arc_set_bg_angles(s_ring, 0, 360);
    lv_arc_set_angles(s_ring, 0, 360);
    lv_obj_remove_style(s_ring, NULL, LV_PART_KNOB);
    lv_obj_set_clickable(s_ring, false);
    lv_obj_set_style_arc_opa(s_ring, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_ring, 6, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(s_ring, lv_color_hex(COLOR_EN), LV_PART_INDICATOR);
    lv_obj_set_hidden(s_ring, true);

    s_text_box = lv_obj_create(scr);
    lv_obj_set_size(s_text_box, 400, 236);
    lv_obj_align(s_text_box, LV_ALIGN_CENTER, 0, -14);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_event_bubble(s_text_box, true);

    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, lv_pct(100));
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_font(s_text, &font_vi_36, 0);
    /* The container gets the theme's dark text colour; force full white on the AMOLED */
    lv_obj_set_style_text_color(s_text, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_line_space(s_text, 2, 0);
    lv_label_set_text(s_text, "Hello!\nOpen the iPhone app to connect.");

    s_btn_mic = lv_button_create(scr);
    lv_obj_set_size(s_btn_mic, 170, 64);
    lv_obj_align(s_btn_mic, LV_ALIGN_BOTTOM_MID, 0, -60);
    lv_obj_set_style_radius(s_btn_mic, 32, 0);
    lv_obj_set_style_bg_color(s_btn_mic, lv_color_hex(COLOR_IDLE), 0);
    lv_obj_set_style_shadow_width(s_btn_mic, 0, 0);
    lv_obj_add_event_cb(s_btn_mic, on_button, LV_EVENT_CLICKED, NULL);

    s_btn_label = lv_label_create(s_btn_mic);
    lv_obj_set_style_text_font(s_btn_label, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_btn_label, lv_color_white(), 0);
    lv_label_set_text(s_btn_label, "Mic off");
    lv_obj_center(s_btn_label);

    lv_label_set_text(s_status, "Waiting for iPhone…");
    lv_obj_add_event_cb(scr, on_double_tap, LV_EVENT_DOUBLE_CLICKED, NULL);
    lv_timer_create(screen_timer_cb, 250, NULL);
    unlock();
}

static void refresh_status(rec_lang_t lang)
{
    if (!s_connected) {
        lv_label_set_text(s_status, "Waiting for iPhone…");
    } else if (lang != REC_NONE) {
        lv_label_set_text(s_status, "Live translation");
    } else {
        lv_label_set_text(s_status, "Board mic is off");
    }
}

void ui_set_connected(bool connected)
{
    lock();
    s_connected = connected;
    refresh_status(app_get_recording());
    unlock();
}

void ui_set_recording(rec_lang_t lang)
{
    lock();
    lv_obj_set_style_bg_color(s_btn_mic, lv_color_hex(lang != REC_NONE ? COLOR_EN : COLOR_IDLE), 0);
    lv_label_set_text(s_btn_label, lang != REC_NONE ? "Mic on" : "Mic off");
    refresh_status(lang);
    unlock();
}

void ui_show_text(const char *utf8)
{
    ui_mark_activity();
    lock();
    lv_label_set_text(s_text, utf8);
    /* Live subtitles: always keep the newest line in view */
    lv_obj_update_layout(s_text_box);
    lv_obj_scroll_to_y(s_text_box, lv_obj_get_scroll_y(s_text_box) + lv_obj_get_scroll_bottom(s_text_box),
                       LV_ANIM_OFF);
    unlock();
}

void ui_show_status(const char *utf8)
{
    lock();
    lv_label_set_text(s_status, utf8);
    unlock();
}
