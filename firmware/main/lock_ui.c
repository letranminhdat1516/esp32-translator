/*
 * Lock screen. Black and empty while the panel is off; a tap shows the face for 5 s:
 *   top    : clock (HH:MM, "--:--" until the iPhone or the Mac sent the time)
 *   middle : static logo (tools/gen_logo.py)
 *   bottom : battery, a gently bouncing chevron and "Vuốt lên để mở khoá"
 * Single tap or PWR x1 → the face, double tap → MODES_EV_TAP_2 (unlock); shell.c / modes.c decide.
 * Swipe up: only a drag that starts on the visible face counts. The face follows the finger, and past
 * SWIPE_PX it slides up and fades out, then MODES_EV_SWIPE_UP unlocks (modes.c re-checks the face is up).
 * On the dark panel a swipe is just a tap (LVGL still sends SINGLE_CLICKED): it shows the face, never unlocks.
 * Animations (chevron bounce, slide-out) run only while the face is visible; lock_ui_set_face(false) stops them.
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
#define SWIPE_PX    60    /* upward drag that unlocks */
#define SLIDE_PX    140   /* the face slides this far up while it fades out */
#define SLIDE_MS    250
#define BOUNCE_PX   10    /* chevron hop */
#define BOUNCE_MS   600
#define RESTORE_MS  800   /* slide-out finished but the board stayed locked: show the face again */

static lv_obj_t *s_scr;
static lv_obj_t *s_face;
static lv_obj_t *s_clock;
static lv_obj_t *s_logo;
static lv_obj_t *s_battery;
static lv_obj_t *s_chevron;
static lv_obj_t *s_hint;
static lv_timer_t *s_tick;
static bool s_face_on;
static char s_clock_text[6];

/* Swipe tracking (LVGL task only) */
static bool s_tracking;        /* a press started on the visible face */
static lv_point_t s_press_at;
static bool s_sliding;         /* slide-out running or done, MODES_EV_SWIPE_UP posted at its end */
static uint32_t s_slid_at;     /* lv_tick when the slide-out finished; 0 = still running */
static int32_t s_slide_from_y;
static lv_opa_t s_slide_from_opa;

/* LVGL task: only queue the input, shell.c applies it */
static void on_single(lv_event_t *e)
{
    shell_post(MODES_EV_TAP_1);
}

static void on_double(lv_event_t *e)
{
    shell_post(MODES_EV_TAP_2);
}

static void face_offset(int32_t y, lv_opa_t opa)
{
    lv_obj_set_style_translate_y(s_face, y, 0);
    lv_obj_set_style_opa(s_face, opa, 0);
}

/* Face back in place, swipe state cleared */
static void face_reset(void)
{
    lv_anim_delete(s_face, NULL);
    s_tracking = false;
    s_sliding = false;
    s_slid_at = 0;
    face_offset(0, LV_OPA_COVER);
}

static lv_point_t touch_point(void)
{
    lv_point_t p = {0, 0};
    lv_indev_t *indev = lv_indev_active();
    if (indev) {
        lv_indev_get_point(indev, &p);
    }
    return p;
}

/* Upward drag distance (positive = up); 0 when the drag is mostly sideways or downwards */
static int32_t drag_up(void)
{
    lv_point_t p = touch_point();
    int32_t up = s_press_at.y - p.y;
    int32_t side = LV_ABS(p.x - s_press_at.x);
    return (up > 0 && up > side) ? up : 0;
}

static void slide_exec(lv_anim_t *a, int32_t v)   /* v: 0..256 */
{
    int32_t y = s_slide_from_y + (-SLIDE_PX - s_slide_from_y) * v / 256;
    face_offset(y, (lv_opa_t)(s_slide_from_opa * (256 - v) / 256));
}

static void slide_done(lv_anim_t *a)
{
    s_slid_at = lv_tick_get() | 1;   /* never 0 */
    shell_post(MODES_EV_SWIPE_UP);   /* the shell loads the unlocked screen; screen timer then hides the face */
}

static void on_press(lv_event_t *e)
{
    if (!s_face_on || s_sliding) {
        return;   /* dark panel: the tap handlers alone apply (pocket guard) */
    }
    s_tracking = true;
    s_press_at = touch_point();
    shell_post(MODES_EV_TAP_1);   /* a finger on the face keeps it up for the whole swipe */
}

static void on_pressing(lv_event_t *e)
{
    if (!s_tracking) {
        return;
    }
    int32_t up = drag_up();
    /* Follow the finger at half speed, fading towards half opacity at the threshold */
    int32_t fade = up >= 2 * SWIPE_PX ? 255 : up * 255 / (2 * SWIPE_PX);
    face_offset(-up / 2, (lv_opa_t)(LV_OPA_COVER - fade / 2));
}

static void on_release(lv_event_t *e)
{
    if (!s_tracking) {
        return;
    }
    s_tracking = false;
    bool unlock = lv_event_get_code(e) == LV_EVENT_RELEASED && drag_up() >= SWIPE_PX;
    if (!unlock) {
        face_offset(0, LV_OPA_COVER);
        return;
    }
    s_sliding = true;
    s_slid_at = 0;
    s_slide_from_y = lv_obj_get_style_translate_y(s_face, 0);
    s_slide_from_opa = lv_obj_get_style_opa(s_face, 0);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, s_face);
    lv_anim_set_custom_exec_cb(&a, slide_exec);
    lv_anim_set_values(&a, 0, 256);
    lv_anim_set_duration(&a, SLIDE_MS);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in);
    lv_anim_set_completed_cb(&a, slide_done);
    lv_anim_start(&a);
}

static void chevron_y(void *obj, int32_t v)
{
    lv_obj_set_style_translate_y(obj, v, 0);
}

static void chevron_bounce(bool on)
{
    lv_anim_delete(s_chevron, chevron_y);
    lv_obj_set_style_translate_y(s_chevron, 0, 0);
    if (!on) {
        return;
    }
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, s_chevron);
    lv_anim_set_exec_cb(&a, chevron_y);
    lv_anim_set_values(&a, 0, -BOUNCE_PX);
    lv_anim_set_duration(&a, BOUNCE_MS);
    lv_anim_set_reverse_duration(&a, BOUNCE_MS);
    lv_anim_set_repeat_delay(&a, 300);
    lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
    lv_anim_start(&a);
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
    /* Safety net: the slide-out ended but the board is still locked with the face up (MODES_EV_SWIPE_UP was
     * refused or dropped): bring the face back instead of leaving a lit, empty screen */
    if (s_sliding && s_slid_at != 0 && lv_tick_elaps(s_slid_at) >= RESTORE_MS) {
        face_reset();
    }
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
        face_reset();
        lv_obj_set_hidden(s_face, false);
        chevron_bounce(true);
        lv_timer_resume(s_tick);
    } else {
        lv_timer_pause(s_tick);
        chevron_bounce(false);   /* no animation runs while the face is hidden */
        face_reset();
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
    lv_obj_add_event_cb(s_scr, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(s_scr, on_pressing, LV_EVENT_PRESSING, NULL);
    lv_obj_add_event_cb(s_scr, on_release, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(s_scr, on_release, LV_EVENT_PRESS_LOST, NULL);

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
    lv_obj_align(s_logo, LV_ALIGN_CENTER, 0, -18);

    s_battery = make_label(&font_vi_22, 0xc8c8c8, LV_ALIGN_BOTTOM_MID, -122);

    /* Up chevron drawn as a line (font_vi_22 has no arrow glyph) */
    static const lv_point_precise_t chevron_pts[] = {{2, 14}, {16, 2}, {30, 14}};
    s_chevron = lv_line_create(s_face);
    lv_line_set_points(s_chevron, chevron_pts, 3);
    lv_obj_set_style_line_width(s_chevron, 4, 0);
    lv_obj_set_style_line_rounded(s_chevron, true, 0);
    lv_obj_set_style_line_color(s_chevron, lv_color_hex(0xc8c8c8), 0);
    lv_obj_set_clickable(s_chevron, false);
    lv_obj_align(s_chevron, LV_ALIGN_BOTTOM_MID, 0, -86);

    s_hint = make_label(&font_vi_22, 0x8c8c8c, LV_ALIGN_BOTTOM_MID, -48);
    lv_label_set_text(s_hint, "Vuốt lên để mở khoá");

    s_tick = lv_timer_create(tick_cb, TICK_MS, NULL);
    lv_timer_pause(s_tick);
    bsp_display_unlock();
}
