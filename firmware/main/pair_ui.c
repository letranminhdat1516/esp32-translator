/*
 * Pairing view (pairing.h): a full screen of its own over whatever was shown (translator, lock, dark panel).
 *   top    : "Ghép với iPhone"
 *   middle : the 6-digit code, large, wide letter spacing
 *   below  : "Mã trên iPhone có giống không?"
 *   bottom : "Sai" (outline) and "Đúng" (blue), 128 x 64 each
 * While it is up, ui.c's screen timer keeps the panel lit and shell.c leaves the screen alone; closing it loads
 * the screen the shell wants now (translator or lock), so the board returns to its mode.
 * The buttons only report the answer (ble_link_pair_answer); the NimBLE host decides and closes the view.
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
static volatile bool s_active;

/* LVGL task: report once, then wait for the host to close the view */
static void on_answer(lv_event_t *e)
{
    bool yes = lv_event_get_target(e) == s_btn_yes;
    lv_obj_set_clickable(s_btn_no, false);
    lv_obj_set_clickable(s_btn_yes, false);
    ble_link_pair_answer(yes);
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

    s_btn_no = make_button("Sai", false, -(BTN_W + BTN_GAP) / 2);
    s_btn_yes = make_button("Đúng", true, (BTN_W + BTN_GAP) / 2);
    bsp_display_unlock();
}

void pair_ui_show(uint32_t passkey, bool ask)
{
    char code[7];
    pair_code_text(passkey, code);
    bsp_display_lock((uint32_t)-1);
    if (!ui_shutting_down()) {
        lv_label_set_text(s_code, code);
        lv_label_set_text(s_question, ask ? "Mã trên iPhone có giống không?" : "Nhập mã này trên iPhone");
        lv_obj_set_hidden(s_btn_no, !ask);
        lv_obj_set_hidden(s_btn_yes, !ask);
        lv_obj_set_clickable(s_btn_no, true);
        lv_obj_set_clickable(s_btn_yes, true);
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
