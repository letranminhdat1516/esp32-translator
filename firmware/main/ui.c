/*
 * Round 466x466 screen ("Phụ đề" style: black, text first, one blue accent):
 *   top    : the other person's language while translating ("English", "日本語"), else the connection state
 *   middle : live subtitles for the other person (streamed by the app while you speak), centred while they fit
 *   bottom : round board mic button (mic icon; slashed and dimmed when off)
 *   edge   : level ring around the rim, brighter and thicker the louder the speaker (hidden in silence)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_timer.h"
#include "lvgl.h"

#include "app.h"
#include "font_store.h"
#include "glyphs.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

#define COLOR_EN      0x1e6fd9
#define COLOR_MUTED   0x8a919c
#define COLOR_LIGHT   0xe3eaf0
#define COLOR_OUTLINE 0x2a2d33
#define COLOR_OFF_BG  0x16171a

/* Status while translating; replaced by the language label (kind 3) alone once the app sent one */
#define LIVE_STATUS "Live translation"
/* Shown while no iPhone is connected (replaces stale subtitles on a disconnect, cleared on connect) */
#define WELCOME_TEXT "Hello!\nOpen the iPhone app to connect."

static lv_obj_t *s_status;
static char s_status_text[96];        /* what the status line says, without the language label */
static char s_label[LABEL_MAX + 1];   /* the other person's language (kind 3); survives reconnects */
static lv_obj_t *s_ring;
static int s_level = -1;
static lv_obj_t *s_text_box;
static lv_obj_t *s_text;
static lv_obj_t *s_btn_mic;
static lv_obj_t *s_mic_body;
static lv_obj_t *s_mic_cradle;
static lv_obj_t *s_mic_stem;
static lv_obj_t *s_mic_slash;
static bool s_connected;

/* Display lock held. While translating the line shows only the language ("English"); any other status
 * (waiting, mic off, a toast) is shown alone, without the label */
static void status_set(const char *utf8)
{
    size_t n = utf8_cut_len(utf8, strlen(utf8), sizeof(s_status_text) - 1);   /* not through a character */
    memcpy(s_status_text, utf8, n);
    s_status_text[n] = '\0';
    bool live = strcmp(s_status_text, LIVE_STATUS) == 0;
    lv_label_set_text(s_status, live && s_label[0] ? s_label : s_status_text);
}


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
static void center_text(void);

static void set_screen(bool on)
{
    if (on == s_screen_on) {
        return;
    }
    s_screen_on = on;
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
    /* Pairing code up: lit whatever the lock or a double-tap says (the policy applies again once it closes) */
    if (pair_ui_active()) {
        set_screen(true);
        return;
    }
    /* Locked: the lock policy alone decides (activity, subtitles and toasts never light a locked panel) */
    int64_t now = esp_timer_get_time();
    modes_t m;
    shell_snapshot(&m);
    lock_ui_set_face(modes_face_visible(&m, now));
    modes_panel_t panel = modes_panel(&m, now);
    if (m.locked && lock_ui_notice_active()) {
        panel = MODES_PANEL_ON;   /* a lock-screen notice (e.g. "unlock to pair") is readable for its 2 s */
    }
    if (panel != MODES_PANEL_AUTO) {
        set_screen(panel == MODES_PANEL_ON);
        return;
    }
    if (s_manual_off) {
        set_screen(false);
        return;
    }
#if defined(CONFIG_TRANSLATOR_DEV_STAY_ON) && CONFIG_TRANSLATOR_DEV_STAY_ON
    set_screen(true);   /* dev build: no idle timeout (lock and double-tap still turn it off above) */
    return;
#endif
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
        lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(100 + percent * 155 / 100), LV_PART_INDICATOR);
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
    status_set(utf8);
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
    status_set("Powering off");
    lv_label_set_text(s_text, "Press the PWR button\nto turn on");
    center_text();
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
    status_set("Sleeping");
    lv_label_set_text(s_text, "Touch the screen\nto wake up");
    center_text();
    unlock();
    vTaskDelay(pdMS_TO_TICKS(2500));
    lock();
    bsp_display_brightness_set(0);
    unlock();
}

/* A mic drawn from shapes (font_vi_22 has no icon glyphs): capsule, cradle arc, stem, and a slash for "off" */
static void build_mic_icon(lv_obj_t *btn)
{
    s_mic_body = lv_obj_create(btn);
    lv_obj_remove_style_all(s_mic_body);
    lv_obj_set_size(s_mic_body, 14, 24);
    lv_obj_set_style_radius(s_mic_body, 7, 0);
    lv_obj_set_style_bg_opa(s_mic_body, LV_OPA_COVER, 0);
    lv_obj_align(s_mic_body, LV_ALIGN_CENTER, 0, -7);

    s_mic_cradle = lv_arc_create(btn);
    lv_obj_set_size(s_mic_cradle, 28, 28);
    lv_obj_align(s_mic_cradle, LV_ALIGN_CENTER, 0, -4);
    lv_arc_set_bg_angles(s_mic_cradle, 0, 180);
    lv_arc_set_angles(s_mic_cradle, 0, 180);
    lv_obj_remove_style(s_mic_cradle, NULL, LV_PART_KNOB);
    lv_obj_set_style_arc_opa(s_mic_cradle, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_mic_cradle, 3, LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(s_mic_cradle, true, LV_PART_INDICATOR);

    s_mic_stem = lv_obj_create(btn);
    lv_obj_remove_style_all(s_mic_stem);
    lv_obj_set_size(s_mic_stem, 3, 7);
    lv_obj_set_style_bg_opa(s_mic_stem, LV_OPA_COVER, 0);
    lv_obj_align(s_mic_stem, LV_ALIGN_CENTER, 0, 13);

    static const lv_point_precise_t slash_pts[] = {{0, 0}, {30, 30}};
    s_mic_slash = lv_line_create(btn);
    lv_line_set_points(s_mic_slash, slash_pts, 2);
    lv_obj_set_style_line_width(s_mic_slash, 3, 0);
    lv_obj_set_style_line_rounded(s_mic_slash, true, 0);
    lv_obj_center(s_mic_slash);

    /* Taps on the icon go to the button */
    lv_obj_t *parts[] = {s_mic_body, s_mic_cradle, s_mic_stem, s_mic_slash};
    for (size_t i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
        lv_obj_set_clickable(parts[i], false);
    }
}

/* On: light icon on black with an outline; off: dimmed, slashed icon on a dark fill */
static void style_mic(bool on)
{
    lv_color_t icon = lv_color_hex(on ? COLOR_LIGHT : COLOR_MUTED);
    lv_obj_set_style_bg_color(s_btn_mic, on ? lv_color_black() : lv_color_hex(COLOR_OFF_BG), 0);
    lv_obj_set_style_border_color(s_btn_mic, lv_color_hex(COLOR_OUTLINE), 0);
    lv_obj_set_style_bg_color(s_mic_body, icon, 0);
    lv_obj_set_style_bg_color(s_mic_stem, icon, 0);
    lv_obj_set_style_arc_color(s_mic_cradle, icon, LV_PART_INDICATOR);
    lv_obj_set_style_line_color(s_mic_slash, icon, 0);
    lv_obj_set_hidden(s_mic_slash, on);
}

/* Display lock held. Subtitles that fit sit in the middle of the box; longer ones start at the top and scroll
 * so the newest line stays in view */
static void center_text(void)
{
    lv_obj_update_layout(s_text_box);
    int32_t box_h = lv_obj_get_content_height(s_text_box);
    int32_t text_h = lv_obj_get_height(s_text);
    lv_obj_set_y(s_text, text_h < box_h ? (box_h - text_h) / 2 : 0);
    lv_obj_update_layout(s_text_box);
    lv_obj_scroll_to_y(s_text_box, lv_obj_get_scroll_y(s_text_box) + lv_obj_get_scroll_bottom(s_text_box),
                       LV_ANIM_OFF);
}

void ui_init(void)
{
    s_last_activity_us = esp_timer_get_time();
    lock();
    font_store_init();   /* script fallbacks of the subtitle fonts, when the fonts partition holds them */
    lv_obj_t *scr = lv_screen_active();
    s_translator_scr = scr;
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_set_style_text_color(scr, lv_color_white(), 0);

    s_status = lv_label_create(scr);
    lv_obj_set_width(s_status, 300);
    lv_obj_set_style_text_font(s_status, font_store_font(22), 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(COLOR_MUTED), 0);
    lv_obj_set_style_text_align(s_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_MODE_DOTS);
    /* One line: dots only cut a label of fixed height; a wrapped toast would run into the subtitles */
    lv_obj_set_height(s_status, lv_font_get_line_height(font_store_font(22)));
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
    /* 360 wide: the top and bottom lines stay inside the round glass. Exactly four lines tall, so a long
     * subtitle scrolled to its newest line never shows half a line at the top */
    lv_obj_set_size(s_text_box, 360, 4 * (lv_font_get_line_height(font_store_font(36)) + 2));
    lv_obj_align(s_text_box, LV_ALIGN_CENTER, 0, -12);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_OFF);
    lv_obj_set_event_bubble(s_text_box, true);

    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, lv_pct(100));
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_font(s_text, font_store_font(36), 0);
    /* The container gets the theme's dark text colour; force full white on the AMOLED */
    lv_obj_set_style_text_color(s_text, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_line_space(s_text, 2, 0);
    lv_label_set_text(s_text, WELCOME_TEXT);
    center_text();

    s_btn_mic = lv_button_create(scr);
    lv_obj_set_size(s_btn_mic, 64, 64);
    lv_obj_align(s_btn_mic, LV_ALIGN_BOTTOM_MID, 0, -50);
    lv_obj_set_style_radius(s_btn_mic, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(s_btn_mic, lv_color_hex(COLOR_OFF_BG), 0);
    lv_obj_set_style_border_width(s_btn_mic, 2, 0);
    lv_obj_set_style_border_color(s_btn_mic, lv_color_hex(COLOR_OUTLINE), 0);
    lv_obj_set_style_shadow_width(s_btn_mic, 0, 0);
    lv_obj_set_ext_click_area(s_btn_mic, 16);
    lv_obj_add_event_cb(s_btn_mic, on_button, LV_EVENT_CLICKED, NULL);
    build_mic_icon(s_btn_mic);
    style_mic(false);

    status_set("Waiting for iPhone");
    lv_obj_add_event_cb(scr, on_double_tap, LV_EVENT_DOUBLE_CLICKED, NULL);
    lv_timer_create(screen_timer_cb, 250, NULL);
    unlock();
}

static void refresh_status(rec_lang_t lang)
{
    if (!s_connected) {
        status_set("Waiting for iPhone");
    } else if (lang != REC_NONE) {
        status_set(LIVE_STATUS);
    } else {
        status_set("Mic off");
    }
}

void ui_set_connected(bool connected)
{
    lock();
    if (connected != s_connected && !s_shutting_down) {   /* keep the sleep / power-off message */
        lv_label_set_text(s_text, connected ? "" : WELCOME_TEXT);
        lv_obj_scroll_to_y(s_text_box, 0, LV_ANIM_OFF);
        center_text();
    }
    s_connected = connected;
    refresh_status(app_get_recording());
    unlock();
}

void ui_set_recording(rec_lang_t lang)
{
    lock();
    style_mic(lang != REC_NONE);
    refresh_status(lang);
    unlock();
}

void ui_show_text(const char *utf8)
{
    ui_mark_activity();
    lock();
    lv_label_set_text(s_text, utf8);
    center_text();   /* live subtitles: centred while they fit, else the newest line in view */
    unlock();
}

void ui_show_status(const char *utf8)
{
    lock();
    status_set(utf8);
    unlock();
}

void ui_set_label(const char *utf8)
{
    lock();
    snprintf(s_label, sizeof(s_label), "%s", utf8);
    status_set(s_status_text);
    unlock();
}
