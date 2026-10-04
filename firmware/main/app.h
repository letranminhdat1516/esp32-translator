#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"
#include "lvgl.h"

/* Board microphone streaming state */
typedef enum {
    REC_NONE = 0,
    REC_EN   = 1,   /* board mic streaming (the other person, English) */
    REC_VI   = 2,   /* reserved */
} rec_lang_t;

/* main.c: every recording state change goes through this queue */
void app_request_recording(rec_lang_t lang);
rec_lang_t app_get_recording(void);
/* iPhone translation link (audio characteristic subscribed) up/down */
void app_on_connection_changed(bool connected);
/* Mac Claude link (answer characteristic subscribed) up/down, and an incoming Claude message */
void app_on_claude_link(bool connected);
void app_on_claude_message(const claude_msg_t *msg);
/* audio_in.c: the board VAD detected the start of speech */
void app_on_speech_activity(void);
/* Shows the sleep screen and enters deep sleep (touch or BOOT wakes) */
void app_enter_deep_sleep(void);
/* PWR double press: switch between apps (translator, Claude companion) */
void app_switch_mode(void);

/* pmu.c: AXP2101 battery gauge and PWR button */
typedef struct {
    bool present;
    bool usb_power;
    bool charging;
    int percent;   /* -1 if unknown */
} pmu_battery_t;
void pmu_start(void);
bool pmu_battery(pmu_battery_t *out);

/* ble_link.c */
void ble_link_init(void);
bool ble_link_audio_ready(void);
uint16_t ble_link_payload_max(void);
bool ble_link_send_audio(const uint8_t *data, uint16_t len);
void ble_link_notify_control(uint8_t state);
bool ble_link_claude_connected(void);
bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);   /* 1 allow, 2 deny */

/* audio_in.c */
void audio_in_start(void);

/* ui.c (takes the LVGL lock itself; do not call from LVGL callbacks) */
void ui_init(void);
void ui_set_connected(bool connected);
void ui_set_recording(rec_lang_t lang);
void ui_show_text(const char *utf8);
void ui_show_status(const char *utf8);
/* Voice level ring around the round screen, 0 = hidden, 1..100 = louder. Safe from any task. */
void ui_set_level(int percent);
/* Keeps the screen on (or wakes it). Safe from any task except LVGL callbacks. */
void ui_mark_activity(void);
/* Shows the sleep message and turns the panel off before deep sleep */
void ui_prepare_sleep(void);
void ui_prepare_power_off(void);
/* Temporarily replaces the status line (and wakes the screen) */
void ui_toast(const char *utf8, uint32_t ms);
/* Translator screen handle, wake override and double-tap gesture for other screens (ui.c) */
lv_obj_t *ui_translator_screen(void);
/* Wakes the panel and clears a double-tap screen-off (within ~250 ms) */
void ui_force_screen_on(void);
void ui_attach_screen_gestures(lv_obj_t *screen);
/* Blanks (true) or wakes (false) the panel like a double-tap. Safe from any task except LVGL callbacks. */
void ui_set_manual_screen_off(bool off);
/* pmu.c: true when external USB power (VBUS) is present; false if the PMU is unavailable */
bool pmu_usb_powered(void);

/* claude_ui.c: Claude companion screen */
void claude_ui_init(void);
void claude_ui_present_request(void);               /* request takes over the screen; restored when done */
bool claude_ui_visible(void);
void claude_ui_on_message(const claude_msg_t *m);   /* copies the text; takes the display lock */
void claude_ui_set_link(bool connected);
void claude_ui_toggle(void);                        /* atomic Translator <-> Claude switch */
void claude_ui_set_touch_enabled(bool on);          /* LVGL task: Allow/Deny ignore taps while the panel is dark */
bool claude_ui_pending(void);                       /* a permission request awaits an answer */

/* chime.c: non-blocking notification chime on the speaker */
typedef enum { CHIME_REQUEST, CHIME_DONE } chime_t;
void chime_start(void);
void chime_play(chime_t kind);
