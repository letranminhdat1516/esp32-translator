/*
 * Lock screen. Black and empty while the panel is off; a tap shows the face for 5 s:
 *   top    : clock (HH:MM, "--:--" until the iPhone or the Mac sent the time)
 *   middle : static logo (tools/gen_logo.py)
 *   bottom : battery
 * Single tap → MODES_EV_TAP_1 (face), double tap → MODES_EV_TAP_2 (unlock); shell.c decides.
 */
#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "lvgl.h"

#include "app.h"
#include "logo_img.h"
#include "clock.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

#define TICK_MS 1000   /* clock refresh while the face is visible */

static lv_obj_t *s_scr;
static lv_obj_t *s_face;
static lv_obj_t *s_clock;
static lv_obj_t *s_logo;
static lv_obj_t *s_battery;
static lv_timer_t *s_tick;
static bool s_face_on;
static char s_clock_text[6];

/* LVGL task: only queue the input, shell.c applies it */
static void on_single(lv_event_t *e)
{
    shell_post(MODES_EV_TAP_1);
}

static void on_double(lv_event_t *e)
{
    shell_post(MODES_EV_TAP_2);
}

static void refresh_clock(void)
{
    char now[6];
    clock_now_hhmm(now);
    if (strcmp(now, s_clock_text) != 0) {   /* a label update redraws: only when the minute changes */
        memcpy(s_clock_text, now, sizeof(now));
        lv_label_set_text(s_clock, now);
    }
}

static void refresh_battery(void)
{
    pmu_battery_t b;
    char text[40];
    if (!pmu_battery(&b)) {
        text[0] = '\0';
    } else if (!b.present) {
        snprintf(text, sizeof(text), "USB power");
    } else if (b.percent < 0) {
        snprintf(text, sizeof(text), "--%%");
    } else {
        snprintf(text, sizeof(text), "%d%%%s", b.percent, b.charging ? " · charging" : "");
    }
    lv_label_set_text(s_battery, text);
}

static void tick_cb(lv_timer_t *t)
{
    refresh_clock();
}

void lock_ui_set_face(bool visible)
{
    if (visible == s_face_on || !s_scr) {
        return;
    }
    s_face_on = visible;
    if (visible) {
        refresh_clock();
        refresh_battery();
        lv_obj_set_hidden(s_face, false);
        lv_timer_resume(s_tick);
    } else {
        lv_timer_pause(s_tick);
        lv_obj_set_hidden(s_face, true);
    }
}

lv_obj_t *lock_ui_screen(void)
{
    return s_scr;
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, lv_align_t align, int y)
{
    lv_obj_t *l = lv_label_create(s_face);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(l, align, 0, y);
    return l;
}

void lock_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_single, LV_EVENT_SINGLE_CLICKED, NULL);
    lv_obj_add_event_cb(s_scr, on_double, LV_EVENT_DOUBLE_CLICKED, NULL);

    /* Everything visible sits in one container that is hidden while the panel is off */
    s_face = lv_obj_create(s_scr);
    lv_obj_remove_style_all(s_face);
    lv_obj_set_size(s_face, lv_pct(100), lv_pct(100));
    lv_obj_set_clickable(s_face, false);   /* taps go to the screen object */
    lv_obj_set_hidden(s_face, true);

    s_clock = make_label(&font_vi_36, 0xffffff, LV_ALIGN_TOP_MID, 64);
    memcpy(s_clock_text, "--:--", 6);
    lv_label_set_text(s_clock, s_clock_text);

    s_logo = lv_image_create(s_face);
    lv_image_set_src(s_logo, &logo_img);
    lv_obj_set_clickable(s_logo, false);
    lv_obj_align(s_logo, LV_ALIGN_CENTER, 0, 4);

    s_battery = make_label(&font_vi_22, 0xc8c8c8, LV_ALIGN_BOTTOM_MID, -72);

    s_tick = lv_timer_create(tick_cb, TICK_MS, NULL);
    lv_timer_pause(s_tick);
    bsp_display_unlock();
}
