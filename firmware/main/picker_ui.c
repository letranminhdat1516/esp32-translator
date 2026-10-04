/*
 * Session picker (PWR x3). Phase 1 placeholder: the session list comes with Phase 2 (Mac daemon session tracking).
 */
#include "bsp/esp-bsp.h"
#include "lvgl.h"

#include "app.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static lv_obj_t *s_scr;

/* LVGL task: a tap on the dark panel ends a manual screen-off (PWR hold on USB) */
static void on_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, int y, const char *text)
{
    lv_obj_t *l = lv_label_create(s_scr);
    lv_obj_set_width(l, 360);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(l, text);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

void picker_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_set_scrollable(s_scr, false);
    lv_obj_add_event_cb(s_scr, on_tap, LV_EVENT_CLICKED, NULL);
    make_label(&font_vi_22, 0xc8c8c8, 48, "Claude sessions");
    make_label(&font_vi_36, 0xffffff, 190, "No sessions yet");
    make_label(&font_vi_22, 0x9a9a9a, 250, "Sessions from your Mac\nwill appear here.");
    bsp_display_unlock();
}

lv_obj_t *picker_ui_screen(void)
{
    return s_scr;
}
