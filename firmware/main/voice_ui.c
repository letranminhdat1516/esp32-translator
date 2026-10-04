/*
 * Voice on the Claude screen (Phase 3): one overlay for every capture (Speak on the session view here; the
 * Other row and Deny + why start captures from question pages and permission requests).
 *   recording : level ring, "Listening…", the live transcript from the Mac, Stop where Speak was
 *   finishing : "One moment…"
 *   confirm   : "Send this?" ("Use this?" for an Other answer) + the final transcript, Say again / Send (Use),
 *               Cancel. Nothing heard: "Didn't catch that" + "Say again, or Cancel.", no Send.
 *   sending   : "Sending…"
 *   result    : "Sent" / "Not sent" + the Mac's line, then back to what is under the overlay
 * An Other answer that was stored, or a deny that was applied, closes the overlay at once (the question page
 * shows the answer, the Claude screen shows "Denied").
 * Flow and bytes: voice.c (host-tested). The mic streams only while recording (audio_in.c, its own task); the
 * Mac transcribes and types. Nothing is sent without an armed, lit tap on Send / Use (claude_ui_tap_armed), and
 * the confirm screen re-arms, so the tap that stopped the recording can never land on Send.
 * Locking: *_locked functions and LVGL callbacks run with the display lock held; the others take it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl.h"

#include "app.h"
#include "voice.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "voice_ui";

#define COLOR_ACCENT 0x1e6fd9
#define COLOR_SEND   0x1f9d55
#define COLOR_GREY   0x3a3a3a
#define COLOR_STOP   0x8a1c1c
#define COLOR_ERROR  0xe0605a

#define RESULT_OK_MS  1500
#define RESULT_ERR_MS 3500
#define WAIT_MAC_MS   10000   /* finishing / sending without an answer from the Mac */

static voice_flow_t s_flow;       /* display lock */
static claude_voice_t s_update;   /* parse buffer: NimBLE host task only, kept off its 6 KB stack */
static uint32_t s_next_id;
static bool s_link;               /* the Mac subscribed to the voice characteristic */
static int s_level = -1;

static lv_obj_t *s_box;
static lv_obj_t *s_ring;
static lv_obj_t *s_title;
static lv_obj_t *s_text_box;
static lv_obj_t *s_text;
static lv_obj_t *s_stop;
static lv_obj_t *s_again;
static lv_obj_t *s_send;
static lv_obj_t *s_send_label;
static lv_obj_t *s_cancel;
static lv_timer_t *s_timer;       /* result close, or the wait for the Mac */

static void stop_timer(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
}

static void start_timer(uint32_t ms, lv_timer_cb_t cb)
{
    stop_timer();
    s_timer = lv_timer_create(cb, ms, NULL);
    lv_timer_set_repeat_count(s_timer, 1);
}

static void redraw(void)
{
    voice_state_t st = s_flow.state;
    bool other = s_flow.purpose == CLAUDE_VOICE_FOR_OTHER;
    const char *title = "";
    const char *body = s_flow.text;
    switch (st) {
    case VOICE_RECORDING:
        title = "Listening…";
        if (body[0] == '\0') {
            body = "Speak now.";
        }
        break;
    case VOICE_FINISHING:
        title = "One moment…";
        break;
    case VOICE_CONFIRM:
        if (s_flow.empty) {
            title = "Didn't catch that";
            body = "Say again, or Cancel.";
        } else {
            title = other ? "Use this?" : "Send this?";
        }
        break;
    case VOICE_SENDING:
        title = "Sending…";
        break;
    case VOICE_RESULT:
        title = s_flow.ok ? "Sent" : "Not sent";
        body = s_flow.note;
        break;
    default:
        body = "";
        break;
    }
    lv_label_set_text(s_title, title);
    lv_obj_set_style_text_color(s_title, lv_color_hex(st == VOICE_RESULT && !s_flow.ok ? COLOR_ERROR : 0xffffff), 0);
    lv_label_set_text(s_text, body);
    lv_obj_update_layout(s_text_box);
    if (st == VOICE_RECORDING || st == VOICE_FINISHING) {
        /* Live transcript: keep the newest words in view */
        lv_obj_scroll_to_y(s_text_box, lv_obj_get_scroll_y(s_text_box) + lv_obj_get_scroll_bottom(s_text_box),
                           LV_ANIM_OFF);
    } else {
        lv_obj_scroll_to_y(s_text_box, 0, LV_ANIM_OFF);
    }
    bool confirm = st == VOICE_CONFIRM;
    lv_obj_set_hidden(s_stop, st != VOICE_RECORDING);
    lv_obj_set_hidden(s_again, !confirm);
    lv_obj_set_hidden(s_cancel, !confirm);
    lv_obj_set_hidden(s_send, !(confirm && !s_flow.empty));
    lv_label_set_text(s_send_label, other ? "Use" : "Send");
    lv_obj_align(s_again, LV_ALIGN_BOTTOM_MID, s_flow.empty ? 0 : -82, -110);
    if (st != VOICE_RECORDING) {
        lv_obj_set_hidden(s_ring, true);
        s_level = 0;
    }
}

/* Hides the overlay; what is under it (session view, permission, question page) shows again */
static void close_overlay(void)
{
    stop_timer();
    lv_obj_set_hidden(s_ring, true);
    lv_obj_set_hidden(s_box, true);
    s_level = 0;
}

static void back_to_screen(uint8_t purpose)
{
    if (purpose == CLAUDE_VOICE_FOR_COMMAND) {
        claude_ui_refresh_session_locked();
    }
    claude_ui_rearm();   /* the controls under the finger are new */
}

/* LVGL timer, lock held: the result was read */
static void result_done_cb(lv_timer_t *t)
{
    s_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    uint8_t purpose = s_flow.purpose;
    voice_reset(&s_flow);
    close_overlay();
    back_to_screen(purpose);
}

/* Lock held: the flow just reached RESULT */
static void on_result(void)
{
    audio_in_voice_abort();   /* an error may arrive while the mic still streams */
    if (s_flow.ok && s_flow.purpose == CLAUDE_VOICE_FOR_OTHER) {
        question_ui_set_other(s_flow.question, s_flow.text);   /* the page shows it, selected */
        voice_reset(&s_flow);
        close_overlay();
        claude_ui_rearm();
        return;
    }
    if (s_flow.ok && s_flow.purpose == CLAUDE_VOICE_FOR_DENY) {
        voice_reset(&s_flow);
        close_overlay();
        claude_ui_voice_denied_locked();
        return;
    }
    start_timer(s_flow.ok ? RESULT_OK_MS : RESULT_ERR_MS, result_done_cb);
}

/* LVGL timer, lock held: no final transcript or no send result from the Mac */
static void wait_cb(lv_timer_t *t)
{
    s_timer = NULL;
    if (s_flow.state != VOICE_FINISHING && s_flow.state != VOICE_SENDING) {
        return;
    }
    bool sending = s_flow.state == VOICE_SENDING;
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = claude_encode_voice(s_flow.id, CLAUDE_INPUT_VOICE_CANCEL, out);
    ble_link_send_claude_input(out, n);
    ESP_LOGW(TAG, "voice %lu: no answer from the Mac", (unsigned long)s_flow.id);
    voice_fail(&s_flow, sending ? "No answer from the Mac. Check the terminal." : "No answer from the Mac.");
    on_result();
    redraw();
}

bool voice_ui_start_locked(uint8_t purpose, uint8_t question, uint32_t target)
{
    if (s_box == NULL || !s_link || voice_active(&s_flow)) {
        return false;
    }
    if (s_flow.state == VOICE_RESULT) {   /* a result still on screen */
        stop_timer();
        voice_reset(&s_flow);
    }
    if (s_next_id == 0) {
        s_next_id = esp_random() | 1u;
    }
    uint32_t id = s_next_id++;
    if (s_next_id == 0) {
        s_next_id = 1;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_begin(&s_flow, id, purpose, question, target, out);
    if (n == 0) {
        return false;
    }
    lv_obj_set_hidden(s_box, false);
    /* The start goes out before the first packet: the audio task only streams after audio_in_voice_start */
    if (!ble_link_voice_ready() || !ble_link_send_claude_input(out, n) || !audio_in_voice_start(id)) {
        ESP_LOGW(TAG, "voice %lu: start not sent (voice link %d)", (unsigned long)id, ble_link_voice_ready());
        voice_fail(&s_flow, "Mac not connected.");
        on_result();
    } else {
        ESP_LOGI(TAG, "voice %lu: start (purpose %u, target %lu)", (unsigned long)id, (unsigned)purpose,
                 (unsigned long)target);
    }
    redraw();
    claude_ui_rearm();   /* Stop sits where Speak was: the tap that started must not stop */
    return true;
}

void voice_ui_cancel_locked(void)
{
    if (s_box == NULL || s_flow.state == VOICE_IDLE) {
        return;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_cancel(&s_flow, out);   /* back to IDLE */
    if (n > 0) {
        ble_link_send_claude_input(out, n);
    }
    audio_in_voice_abort();
    close_overlay();
}

void voice_ui_request_gone_locked(uint32_t id)
{
    if (s_flow.state != VOICE_IDLE && s_flow.purpose != CLAUDE_VOICE_FOR_COMMAND && s_flow.target == id) {
        voice_ui_cancel_locked();
    }
}

bool voice_ui_active_locked(void)
{
    return s_flow.state != VOICE_IDLE;
}

static void on_pressed(lv_event_t *e)
{
    claude_ui_note_press();
}

static void on_stop(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_RECORDING) {
        return;
    }
    audio_in_voice_stop();   /* the audio task sends the last packet, the stop, then voice_ui_capture_ended */
}

static void on_again(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_CONFIRM) {
        return;
    }
    uint8_t purpose = s_flow.purpose;
    uint8_t question = s_flow.question;
    uint32_t target = s_flow.target;
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_cancel(&s_flow, out);
    if (n > 0) {
        ble_link_send_claude_input(out, n);
    }
    if (!voice_ui_start_locked(purpose, question, target)) {
        close_overlay();
        back_to_screen(purpose);
    }
}

static void on_cancel(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_CONFIRM) {
        return;
    }
    uint8_t purpose = s_flow.purpose;
    voice_ui_cancel_locked();
    back_to_screen(purpose);
}

static void on_send(lv_event_t *e)
{
    if (!claude_ui_tap_armed()) {
        return;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_send(&s_flow, out);   /* only from CONFIRM with a transcript */
    if (n == 0) {
        return;
    }
    if (ble_link_send_claude_input(out, n)) {
        ESP_LOGI(TAG, "voice %lu: send", (unsigned long)s_flow.id);
        start_timer(WAIT_MAC_MS, wait_cb);
    } else {
        voice_fail(&s_flow, "Mac not connected.");
        on_result();
    }
    redraw();
}

/* Dark panel: the box is not clickable, so a tap reaches the screen and wakes it; the text box takes presses
 * (to scroll), so it wakes the panel itself */
static void on_text_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, lv_event_cb_t cb, lv_obj_t **label_out)
{
    lv_obj_t *b = lv_button_create(s_box);
    lv_obj_set_size(b, width, 52);
    lv_obj_set_style_radius(b, 26, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_add_event_cb(b, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    if (label_out) {
        *label_out = l;
    }
    return b;
}

/* Layout on the 466 px circle (centre 233): title y 64 (320 wide), transcript y 122..292 (380 wide, scrolls),
 * Stop at the Speak spot (bottom -70), Say again / Send at bottom -110 (x -82 / +82), Cancel at bottom -48.
 * Every corner stays within r 222 of the centre. */
void voice_ui_init(lv_obj_t *scr)
{
    s_box = lv_obj_create(scr);   /* opaque, covers the Claude screen and question pages while shown */
    lv_obj_set_size(s_box, 466, 466);
    lv_obj_center(s_box);
    lv_obj_set_style_bg_color(s_box, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_box, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_box, 0, 0);
    lv_obj_set_style_radius(s_box, 0, 0);
    lv_obj_set_style_pad_all(s_box, 0, 0);
    lv_obj_set_scrollable(s_box, false);
    lv_obj_set_clickable(s_box, false);

    s_ring = lv_arc_create(s_box);
    lv_obj_set_size(s_ring, 462, 462);
    lv_obj_center(s_ring);
    lv_arc_set_bg_angles(s_ring, 0, 360);
    lv_arc_set_angles(s_ring, 0, 360);
    lv_obj_remove_style(s_ring, NULL, LV_PART_KNOB);
    lv_obj_set_clickable(s_ring, false);
    lv_obj_set_style_arc_opa(s_ring, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_ring, 6, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(s_ring, lv_color_hex(COLOR_ACCENT), LV_PART_INDICATOR);
    lv_obj_set_hidden(s_ring, true);

    s_title = lv_label_create(s_box);
    lv_obj_set_width(s_title, 320);
    lv_obj_set_style_text_font(s_title, &font_vi_36, 0);
    lv_obj_set_style_text_color(s_title, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_title, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(s_title, LV_ALIGN_TOP_MID, 0, 64);

    s_text_box = lv_obj_create(s_box);
    lv_obj_set_size(s_text_box, 380, 170);
    lv_obj_align(s_text_box, LV_ALIGN_TOP_MID, 0, 122);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_style_radius(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_add_event_cb(s_text_box, on_text_tap, LV_EVENT_CLICKED, NULL);
    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, 380);
    lv_obj_set_style_text_font(s_text, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_text, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(s_text, LV_ALIGN_TOP_MID, 0, 0);

    s_stop = make_button("Stop", COLOR_STOP, 150, on_stop, NULL);
    lv_obj_align(s_stop, LV_ALIGN_BOTTOM_MID, 0, -70);
    s_again = make_button("Say again", COLOR_GREY, 150, on_again, NULL);
    lv_obj_align(s_again, LV_ALIGN_BOTTOM_MID, -82, -110);
    s_send = make_button("Send", COLOR_SEND, 150, on_send, &s_send_label);
    lv_obj_align(s_send, LV_ALIGN_BOTTOM_MID, 82, -110);
    s_cancel = make_button("Cancel", COLOR_GREY, 130, on_cancel, NULL);
    lv_obj_align(s_cancel, LV_ALIGN_BOTTOM_MID, 0, -48);

    voice_reset(&s_flow);
    redraw();
    lv_obj_set_hidden(s_box, true);
}

void voice_ui_on_message(const claude_msg_t *m)
{
    if (!claude_parse_voice(m, &s_update)) {
        ESP_LOGW(TAG, "ignoring bad voice message for %lu", (unsigned long)m->id);
        return;
    }
    bsp_display_lock((uint32_t)-1);
    voice_state_t before = s_flow.state;
    if (s_box != NULL && voice_on_update(&s_flow, &s_update)) {
        if (s_flow.state == VOICE_CONFIRM && before != VOICE_CONFIRM) {
            /* Debug: NimBLE host task stack headroom (bytes never used), once per capture */
            ESP_LOGI(TAG, "stack headroom %s: %u bytes", pcTaskGetName(NULL),
                     (unsigned)uxTaskGetStackHighWaterMark(NULL));
            stop_timer();
            claude_ui_rearm();   /* Send appears: only a new press may use it */
        }
        if (s_flow.state == VOICE_RESULT) {
            on_result();
        }
        if (s_flow.state != VOICE_IDLE) {
            redraw();
        }
    }
    bsp_display_unlock();
}

void voice_ui_set_link(bool on)
{
    bsp_display_lock((uint32_t)-1);
    s_link = on;
    if (!on && s_box != NULL && s_flow.state != VOICE_IDLE) {
        audio_in_voice_abort();
        voice_reset(&s_flow);
        close_overlay();
    }
    bsp_display_unlock();
}

void voice_ui_capture_ended(uint32_t id)
{
    bsp_display_lock((uint32_t)-1);
    if (s_box != NULL && voice_captured(&s_flow, id)) {
        start_timer(WAIT_MAC_MS, wait_cb);
        redraw();
    }
    bsp_display_unlock();
}

void voice_ui_level(int percent)
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
    bsp_display_lock((uint32_t)-1);
    s_level = percent;
    if (s_box != NULL && s_flow.state == VOICE_RECORDING) {
        lv_obj_set_hidden(s_ring, percent == 0);
        if (percent != 0) {
            lv_obj_set_style_arc_width(s_ring, 3 + percent / 12, LV_PART_INDICATOR);
            lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(60 + percent * 195 / 100), LV_PART_INDICATOR);
        }
    }
    bsp_display_unlock();
}
