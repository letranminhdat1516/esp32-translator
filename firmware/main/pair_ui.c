/*
 * Pairing view (pairing.h): a full screen of its own over the translator (never on a locked board: ble_link.c
 * refuses the request and the shell cancels a shown code when the board locks).
 *   top    : "Ghép với iPhone"
 *   middle : the 6-digit code, large, wide letter spacing
 *   below  : "Mã trên iPhone có giống không?"
 *   bottom : "Sai" (outline) and "Đúng" (blue), 128 x 64 each
 * While it is up, ui.c's screen timer keeps the panel lit and shell.c leaves the screen alone; closing it loads
 * the screen the shell wants now (translator or lock), so the board returns to its mode.
 * The buttons only report the answer for the request they were shown for (ble_link_pair_answer(conn, id, yes)); the
 * NimBLE host decides and closes the view. For PAIR_ARM_MS after a code appears the buttons are disabled (dimmed,
 * taps ignored): a tap meant for the screen underneath cannot confirm a new code.
 */
#include <stdio.h>

#include "bsp/esp-bsp.h"
#include "lvgl.h"

#include "app.h"
#include "pairing.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

#define COLOR_YES     0x1e6fd9
#define COLOR_MUTED   0x8a919c
#define COLOR_OUTLINE 0x3a3e46
#define COLOR_OFF_BG  0x16171a

#define BTN_W   128
#define BTN_H   64
#define BTN_GAP 20

static lv_obj_t *s_scr;
static lv_obj_t *s_code;
static lv_obj_t *s_question;
static lv_obj_t *s_btn_no;
static lv_obj_t *s_btn_yes;
static lv_timer_t *s_arm_timer;
static volatile bool s_active;
/* The request on screen (display lock) */
static uint16_t s_conn = PAIR_CONN_NONE;
static volatile uint32_t s_id = PAIR_ID_NONE;
static uint32_t s_shown_at;   /* lv_tick */

static void set_buttons_enabled(bool on)
{
    lv_obj_set_state(s_btn_no, LV_STATE_DISABLED, !on);
    lv_obj_set_state(s_btn_yes, LV_STATE_DISABLED, !on);
}

/* LVGL task: PAIR_ARM_MS after the code appeared */
static void on_armed(lv_timer_t *t)
{
    (void)t;
    s_arm_timer = NULL;   /* one-shot: LVGL deletes it */
    if (s_active) {
        set_buttons_enabled(true);
    }
}

/* LVGL task: report once, then wait for the host to close the view */
static void on_answer(lv_event_t *e)
{
    if (!s_active || lv_tick_elaps(s_shown_at) < PAIR_ARM_MS) {
        return;   /* disabled objects get no clicks; checked again so a queued event cannot slip through */
    }
    bool yes = lv_event_get_target(e) == s_btn_yes;
    lv_obj_set_clickable(s_btn_no, false);
    lv_obj_set_clickable(s_btn_yes, false);
    ble_link_pair_answer(s_conn, s_id, yes);
}

static lv_obj_t *make_button(const char *text, bool primary, int32_t x)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, BTN_W, BTN_H);
    lv_obj_align(b, LV_ALIGN_CENTER, x, 108);
    lv_obj_set_style_radius(b, BTN_H / 2, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(primary ? COLOR_YES : COLOR_OFF_BG), 0);
    lv_obj_set_style_border_width(b, primary ? 0 : 2, 0);
    lv_obj_set_style_border_color(b, lv_color_hex(COLOR_OUTLINE), 0);
    lv_obj_set_style_opa(b, LV_OPA_40, LV_STATE_DISABLED);
    lv_obj_add_event_cb(b, on_answer, LV_EVENT_CLICKED, NULL);

    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

void pair_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_style_text_color(s_scr, lv_color_white(), 0);
    lv_obj_set_scrollable(s_scr, false);

    lv_obj_t *title = lv_label_create(s_scr);
    lv_obj_set_style_text_font(title, &font_vi_22, 0);
    lv_obj_set_style_text_color(title, lv_color_hex(COLOR_MUTED), 0);
    lv_label_set_text(title, "Ghép với iPhone");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 84);

    s_code = lv_label_create(s_scr);
    lv_obj_set_style_text_font(s_code, &font_vi_36, 0);
    lv_obj_set_style_text_color(s_code, lv_color_white(), 0);
    lv_obj_set_style_text_letter_space(s_code, 10, 0);
    /* 1.5x of the 36 px font: the code is what the owner reads from arm's length */
    lv_obj_set_style_transform_scale(s_code, 384, 0);
    lv_label_set_text(s_code, "000000");
    lv_obj_align(s_code, LV_ALIGN_CENTER, 0, -52);
    lv_obj_update_layout(s_code);
    lv_obj_set_style_transform_pivot_x(s_code, lv_obj_get_width(s_code) / 2, 0);
    lv_obj_set_style_transform_pivot_y(s_code, lv_obj_get_height(s_code) / 2, 0);

    s_question = lv_label_create(s_scr);
    lv_obj_set_width(s_question, 400);   /* one line: the glass is ~440 px wide at this height */
    lv_obj_set_style_text_font(s_question, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_question, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_question, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_question, LV_ALIGN_CENTER, 0, 36);
    lv_label_set_text(s_question, "Mã trên iPhone có giống không?");

    s_btn_no = make_button("Sai", false, -(BTN_W + BTN_GAP) / 2);
    s_btn_yes = make_button("Đúng", true, (BTN_W + BTN_GAP) / 2);
    bsp_display_unlock();
}

void pair_ui_show(uint16_t conn, uint32_t id, uint32_t passkey)
{
    char code[7];
    pair_code_text(passkey, code);
    bsp_display_lock((uint32_t)-1);
    if (!ui_shutting_down()) {
        s_conn = conn;
        s_id = id;
        s_shown_at = lv_tick_get();
        lv_label_set_text(s_code, code);
        lv_obj_set_clickable(s_btn_no, true);
        lv_obj_set_clickable(s_btn_yes, true);
        set_buttons_enabled(false);
        if (s_arm_timer != NULL) {
            lv_timer_delete(s_arm_timer);
        }
        s_arm_timer = lv_timer_create(on_armed, PAIR_ARM_MS, NULL);
        lv_timer_set_repeat_count(s_arm_timer, 1);
        s_active = true;   /* before the load: the screen timer lights the panel on this screen */
        lv_screen_load(s_scr);
    }
    bsp_display_unlock();
    ui_mark_activity();   /* back on the translator, the screen stays on a while after the pairing */
}

void pair_ui_close(void)
{
    bsp_display_lock((uint32_t)-1);
    if (s_active) {
        s_active = false;
        s_id = PAIR_ID_NONE;
        if (s_arm_timer != NULL) {
            lv_timer_delete(s_arm_timer);
            s_arm_timer = NULL;
        }
        if (!ui_shutting_down() && lv_screen_active() == s_scr) {
            modes_t m;
            shell_snapshot(&m);
            lv_screen_load(modes_screen(&m) == SCREEN_LOCK ? lock_ui_screen() : ui_translator_screen());
        }
    }
    bsp_display_unlock();
}

bool pair_ui_active(void)
{
    return s_active;
}

uint32_t pair_ui_request_id(void)
{
    return s_active ? s_id : PAIR_ID_NONE;
}
