/*
 * Giao diện màn tròn 466x466:
 *   trên  : dòng trạng thái (kết nối / đang nghe)
 *   giữa  : phụ đề tiếng Anh cho người đối diện đọc (app gửi liên tục khi bạn nói)
 *   dưới  : nút bật/tắt mic của board
 */
#include "bsp/esp-bsp.h"
#include "lvgl.h"

#include "app.h"

LV_FONT_DECLARE(font_vi_20);
LV_FONT_DECLARE(font_vi_26);

#define COLOR_IDLE  0x2a2a2a
#define COLOR_EN    0x1e6fd9
#define COLOR_MUTED 0x9a9a9a

static lv_obj_t *s_status;
static lv_obj_t *s_text_box;
static lv_obj_t *s_text;
static lv_obj_t *s_btn_mic;
static lv_obj_t *s_btn_label;
static bool s_connected;

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
    /* Chỉ đẩy yêu cầu vào hàng đợi; đang ở trong task LVGL nên không đụng UI tại đây */
    app_request_recording(app_get_recording() == REC_NONE ? REC_EN : REC_NONE);
}

void ui_init(void)
{
    lock();
    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_set_style_text_color(scr, lv_color_white(), 0);

    s_status = lv_label_create(scr);
    lv_obj_set_width(s_status, 300);
    lv_obj_set_style_text_font(s_status, &font_vi_20, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(COLOR_MUTED), 0);
    lv_obj_set_style_text_align(s_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(s_status, LV_ALIGN_TOP_MID, 0, 48);

    s_text_box = lv_obj_create(scr);
    lv_obj_set_size(s_text_box, 380, 220);
    lv_obj_align(s_text_box, LV_ALIGN_CENTER, 0, -18);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_OFF);

    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, lv_pct(100));
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_set_style_text_font(s_text, &font_vi_26, 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(s_text, "Xin chào!\nMở app trên iPhone để kết nối.");

    s_btn_mic = lv_button_create(scr);
    lv_obj_set_size(s_btn_mic, 170, 64);
    lv_obj_align(s_btn_mic, LV_ALIGN_BOTTOM_MID, 0, -60);
    lv_obj_set_style_radius(s_btn_mic, 32, 0);
    lv_obj_set_style_bg_color(s_btn_mic, lv_color_hex(COLOR_IDLE), 0);
    lv_obj_set_style_shadow_width(s_btn_mic, 0, 0);
    lv_obj_add_event_cb(s_btn_mic, on_button, LV_EVENT_CLICKED, NULL);

    s_btn_label = lv_label_create(s_btn_mic);
    lv_obj_set_style_text_font(s_btn_label, &font_vi_20, 0);
    lv_label_set_text(s_btn_label, "Mic tắt");
    lv_obj_center(s_btn_label);

    lv_label_set_text(s_status, "Đang chờ iPhone…");
    unlock();
}

static void refresh_status(rec_lang_t lang)
{
    if (!s_connected) {
        lv_label_set_text(s_status, "Đang chờ iPhone…");
    } else if (lang != REC_NONE) {
        lv_label_set_text(s_status, "Đang dịch trực tiếp");
    } else {
        lv_label_set_text(s_status, "Mic board đang tắt");
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
    lv_label_set_text(s_btn_label, lang != REC_NONE ? "Mic bật" : "Mic tắt");
    refresh_status(lang);
    unlock();
}

void ui_show_text(const char *utf8)
{
    lock();
    lv_label_set_text(s_text, utf8);
    /* Phụ đề trực tiếp: luôn hiện dòng mới nhất ở cuối */
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
