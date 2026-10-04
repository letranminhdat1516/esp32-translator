/*
 * iPhone notice screen (Phase 4): one Claude app notification from the iPhone (ANCS, ancs_client.c).
 *   top    : "iPhone · Claude"
 *   middle : title (large), subtitle, message
 *   bottom : the iPhone's own actions when it offers them: negative (left, red) / positive (right, green), with
 *            the iPhone's labels; Close below (board only: the notification stays on the iPhone)
 * phone_ui_show() fills it and posts MODES_EV_NOTICE: the shell loads this screen over any mode or the lock (a
 * Mac request wins, modes.c). It goes away on Close, after NOTICE_SHOW_MS (NOTICE_ACTIONS_MS with actions),
 * when the iPhone removes the notification, at once when the iPhone link drops, on any button (PWR x1 only
 * closes it) or a Mac request. Leaving it forgets the notice (labels cleared, ancs_client_close), so nothing is
 * kept; a newer notice that arrived after the close was asked is kept for the MODES_EV_NOTICE that follows.
 * An action is written to the iPhone only from an explicit tap on its button, armed ARM_DELAY_US after the
 * notice appears, changes or the panel lights, never from a dark panel, only while the link is up, and only for
 * the notice on screen (ancs_flow_action checks the uid). The positive action is refused while the board is locked
 * (ancs_action_allowed: "Unlock to confirm"); the negative action and Close still work. The result shows for
 * RESULT_MS, then the screen closes. A close that cannot be posted (shell queue full) is retried every
 * CLOSE_RETRY_MS while this screen is up, so the panel never stays lit on it.
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

#define NOTICE_SHOW_MS    20000       /* a notice without actions closes itself after this */
#define NOTICE_ACTIONS_MS 60000       /* with action buttons: time to decide */
#define RESULT_MS         1500
#define ARM_DELAY_US      (700 * 1000)
#define CLOSE_RETRY_MS    1000
#define HEADER_TEXT       "iPhone · Claude"

/* All under the display lock */
static lv_obj_t *s_scr;
static lv_obj_t *s_header;
static lv_obj_t *s_title;
static lv_obj_t *s_subtitle;
static lv_obj_t *s_message;
static lv_obj_t *s_negative;
static lv_obj_t *s_positive;
static lv_obj_t *s_close;
static lv_timer_t *s_close_timer;
static bool s_on;                     /* a notice is held (shown, or waiting for the shell to load the screen) */
static uint32_t s_uid;                /* its ANCS uid (0 is a valid uid) */
static bool s_has_pos;                /* the iPhone offers these actions for it */
static bool s_has_neg;
static bool s_busy;                   /* an action was sent, the iPhone has not answered yet */
static bool s_result;                 /* a result is shown; the screen closes after RESULT_MS */
static bool s_link_up;                /* the ANCS link is up (actions possible) */
static bool s_close_req;              /* this screen asked the shell to close s_close_uid (MODES_EV_NOTICE_DONE) */
static uint32_t s_close_uid;
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

static uint32_t show_ms(void)
{
    return (s_has_pos || s_has_neg) ? NOTICE_ACTIONS_MS : NOTICE_SHOW_MS;
}

/* Asks the shell to close the notice on screen; remembers which one, so a newer notice that arrives before the
 * shell gets to it is not forgotten with it (on_unloaded) */
static bool request_close(void)
{
    s_close_req = true;
    s_close_uid = s_uid;
    return shell_post(MODES_EV_NOTICE_DONE);
}

static void close_cb(lv_timer_t *t)
{
    s_close_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    if (!request_close() && lv_screen_active() == s_scr) {
        /* The shell queue was full: try again, or the panel could stay lit on this screen forever */
        ESP_LOGW(TAG, "close not posted (queue full): retrying");
        s_close_timer = lv_timer_create(close_cb, CLOSE_RETRY_MS, NULL);
        lv_timer_set_repeat_count(s_close_timer, 1);
    }
}

static void stop_close_timer(void)
{
    if (s_close_timer) {
        lv_timer_delete(s_close_timer);
        s_close_timer = NULL;
    }
}

static void restart_close_timer(uint32_t ms)
{
    stop_close_timer();
    s_close_timer = lv_timer_create(close_cb, ms, NULL);
    lv_timer_set_repeat_count(s_close_timer, 1);
}

/* Buttons and message height for the current state. Deny-like left, Allow-like right (as on the Claude screen);
 * a single action is centred and wider. */
static void layout(void)
{
    bool actions = s_link_up && !s_busy && !s_result;
    bool pos = actions && s_has_pos;
    bool neg = actions && s_has_neg;
    lv_obj_set_hidden(s_positive, !pos);
    lv_obj_set_hidden(s_negative, !neg);
    if (pos && neg) {
        lv_obj_set_width(s_negative, 150);
        lv_obj_align(s_negative, LV_ALIGN_BOTTOM_MID, -80, -140);
        lv_obj_set_width(s_positive, 150);
        lv_obj_align(s_positive, LV_ALIGN_BOTTOM_MID, 80, -140);
    } else if (pos || neg) {
        lv_obj_t *b = pos ? s_positive : s_negative;
        lv_obj_set_width(b, 220);
        lv_obj_align(b, LV_ALIGN_BOTTOM_MID, 0, -140);
    }
    lv_obj_set_height(s_message, (pos || neg) ? 96 : 150);   /* y 166..262 above the actions, else ..316 */
    lv_obj_set_hidden(s_close, s_busy);
}

static void show_result(const char *title, const char *detail)
{
    s_busy = false;
    s_result = true;
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_subtitle, "");
    lv_obj_set_hidden(s_subtitle, true);
    lv_label_set_text(s_message, detail);
    layout();
    restart_close_timer(RESULT_MS);
}

/* Drops the notice: no timer, no text, the flow forgets it too */
static void forget(void)
{
    stop_close_timer();
    if (s_on) {
        ancs_client_close(s_uid);
        s_on = false;
    }
    s_has_pos = s_has_neg = s_busy = s_result = s_close_req = false;
    lv_label_set_text(s_header, HEADER_TEXT);
    lv_label_set_text(s_title, "");
    lv_label_set_text(s_subtitle, "");
    lv_label_set_text(s_message, "");
    lv_label_set_text(lv_obj_get_child(s_positive, 0), "");
    lv_label_set_text(lv_obj_get_child(s_negative, 0), "");
    layout();
}

/* Shell task inside lv_screen_load (display lock held) */
static void on_loaded(lv_event_t *e)
{
    if (!s_on) {
        /* Nothing held (forgotten between the post and the load): never sit on an empty notice */
        shell_post(MODES_EV_NOTICE_DONE);
        return;
    }
    arm();
    restart_close_timer(s_result ? RESULT_MS : show_ms());
}

static void on_unloaded(lv_event_t *e)
{
    if (s_close_req && s_on && s_uid != s_close_uid) {
        /* A newer notice replaced the one whose close was asked: keep it for the MODES_EV_NOTICE queued
         * behind (on_loaded restarts its timer and arming); the flow already forgot the older one */
        ESP_LOGI(TAG, "notice %lu closed, %lu kept for the next load", (unsigned long)s_close_uid,
                 (unsigned long)s_uid);
        ancs_client_close(s_close_uid);
        s_close_req = false;
        stop_close_timer();
        return;
    }
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
        request_close();
    }
}

/* LVGL task: the only path to an iPhone action */
static void on_action(lv_event_t *e)
{
    uint8_t action = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    if (!tap_armed() || !s_on || s_busy || s_result || s_close_req || !s_link_up) {
        return;
    }
    if (action == ANCS_ACTION_POSITIVE ? !s_has_pos : !s_has_neg) {
        return;
    }
    modes_t m;
    shell_snapshot(&m);
    if (!ancs_action_allowed(action, m.locked)) {
        lv_label_set_text(s_header, "Unlock to confirm");   /* until the next notice or the close */
        ESP_LOGI(TAG, "positive action for %lu refused: the board is locked", (unsigned long)s_uid);
        return;
    }
    lv_label_set_text(s_header, HEADER_TEXT);
    if (!ancs_client_perform(s_uid, action)) {
        show_result("Not sent", "The iPhone is not connected.");
        return;
    }
    s_busy = true;
    lv_label_set_text(s_message, "Sending to the iPhone…");
    layout();
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
    lv_label_set_text(s_header, HEADER_TEXT);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 86, 46);
    s_subtitle = make_label(&font_vi_22, 0x9a9a9a, 360, 134, 28);
    s_message = make_label(&font_vi_22, 0xffffff, 380, 166, 150);
    /* Actions at y 270..326 (as Deny / Allow on the Claude screen), Close below at y 336..392 */
    s_negative = make_button("", 0x8a1c1c, 150, -80, -140, on_action, ANCS_ACTION_NEGATIVE);
    s_positive = make_button("", 0x1f9d55, 150, 80, -140, on_action, ANCS_ACTION_POSITIVE);
    s_close = make_button("Close", 0x333333, 150, 0, -74, on_close, 0);
    layout();
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
    s_busy = false;     /* a newer notice replaces any action in progress: its late answer no longer matches */
    s_result = false;
    s_has_pos = n->positive[0] != '\0';
    s_has_neg = n->negative[0] != '\0';
    lv_label_set_text(s_header, HEADER_TEXT);
    lv_label_set_text(s_title, n->title[0] ? n->title : "Claude");
    lv_label_set_text(s_subtitle, n->subtitle);
    lv_obj_set_hidden(s_subtitle, n->subtitle[0] == '\0');
    lv_label_set_text(s_message, n->message);
    lv_label_set_text(lv_obj_get_child(s_positive, 0), n->positive);
    lv_label_set_text(lv_obj_get_child(s_negative, 0), n->negative);
    layout();
    arm();   /* new buttons under the finger: a tap already on its way must not count */
    if (lv_screen_active() == s_scr) {
        restart_close_timer(show_ms());
    }
    bsp_display_unlock();
    ESP_LOGI(TAG, "notice %lu %s (actions:%s%s)", (unsigned long)n->uid, fresh ? "shown" : "updated",
             s_has_neg ? " negative" : "", s_has_pos ? " positive" : "");
    shell_post(MODES_EV_NOTICE);   /* takes the screen and wakes the panel (also when locked) */
}

void phone_ui_gone(uint32_t uid)
{
    bsp_display_lock((uint32_t)-1);
    bool mine = s_on && s_uid == uid && !s_busy && !s_result;   /* an action's result closes by itself */
    if (mine) {
        if (lv_screen_active() == s_scr) {
            request_close();
        } else {
            forget();   /* it never got the screen (a Mac request had it): just forget it */
        }
    }
    bsp_display_unlock();
}

void phone_ui_action_result(uint32_t uid, bool ok)
{
    bsp_display_lock((uint32_t)-1);
    if (s_on && s_busy && s_uid == uid) {
        show_result(ok ? "Done" : "Not done", ok ? "Sent to the iPhone." : "The iPhone refused it.");
    }
    bsp_display_unlock();
}

void phone_ui_set_link(bool up)
{
    bsp_display_lock((uint32_t)-1);
    s_link_up = up;
    if (s_scr != NULL) {
        if (!up && s_on) {
            /* The notice belongs to the link that is gone: buttons off now, the screen closes at once */
            s_busy = false;
            layout();
            if (lv_screen_active() == s_scr) {
                request_close();
            } else {
                forget();
            }
        } else {
            layout();
        }
    }
    bsp_display_unlock();
    ESP_LOGI(TAG, "iPhone link %s", up ? "up: actions possible" : "gone: notice closed, no actions");
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
    /* Not clickable: the tap falls through to the screen object and only wakes the panel */
    lv_obj_set_clickable(s_close, on);
    lv_obj_set_clickable(s_positive, on);
    lv_obj_set_clickable(s_negative, on);
}
