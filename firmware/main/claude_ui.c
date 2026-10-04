/*
 * Claude companion screen:
 *   top    : "Claude" + link state
 *   middle : project (grey), tool (bold), one-line summary
 *   bottom : Deny / Allow while a permission request is pending
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 */
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
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
static void on_answer(lv_event_t *e)
{
    uint8_t decision = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    /* A tap on a dark panel only wakes it; it must never answer blind */
    if (s_pending_id == 0 || !s_touch_on) {
        return;
    }
    bool sent = ble_link_send_claude_answer(s_pending_id, decision);
    ESP_LOGI(TAG, "answer %s for %lu (%s)", decision == 1 ? "allow" : "deny",
             (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    show_idle(decision == 1 ? "Allowed" : "Denied", sent ? "Claude continues." : "Mac not connected.");
}

static lv_obj_t *make_button(const char *text, uint32_t color, int x, uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, 150, 64);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, -60);
    lv_obj_set_style_radius(b, 32, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
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
    s_project = make_label(&font_vi_22, 0x9a9a9a, 360, 110);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 146);
    s_detail = make_label(&font_vi_22, 0xffffff, 380, 200);
    lv_obj_set_height(s_detail, 120);
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_DOTS);

    s_deny = make_button("Deny", 0x8a1c1c, -80, 2);
    s_allow = make_button("Allow", 0x1f9d55, 80, 1);

    lv_label_set_text(s_status, "Claude · Mac not connected");
    show_idle("No requests", "Claude Code permission\nprompts will appear here.");
    bsp_display_unlock();
}

void claude_ui_show(bool show)
{
    bsp_display_lock((uint32_t)-1);
    lv_screen_load(show ? s_scr : ui_translator_screen());
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
        break;
    case CLAUDE_CANCEL:
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
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
    lv_screen_load(lv_screen_active() == s_scr ? ui_translator_screen() : s_scr);
    bsp_display_unlock();
}
