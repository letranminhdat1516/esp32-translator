#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "lvgl.h"
#include "modes.h"

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
/* audio_in.c: the board VAD detected the start of speech */
void app_on_speech_activity(void);
/* Shows the sleep screen and enters deep sleep (touch or BOOT wakes) */
void app_enter_deep_sleep(void);

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
/* Board mic tapped without the iPhone audio role: if an iPhone link waits for the app, take it back (async, NimBLE
 * host task) and request lang again; false: no such link */
bool ble_link_wake_phone(rec_lang_t lang);
/* The owner's answer on the pairing view (Đúng = true) for request id on link conn (pair_ui_show's arguments).
 * LVGL task; posts to the NimBLE host, which injects it only if that request is still the one on screen. */
void ble_link_pair_answer(uint16_t conn, uint32_t id, bool yes);
/* The board locked: reject and close a code that is up (async, NimBLE host task; nothing if none). Any task. */
void ble_link_pair_cancel(void);

/* audio_in.c */
void audio_in_start(void);

/* ui.c (takes the LVGL lock itself; do not call from LVGL callbacks) */
void ui_init(void);
void ui_set_connected(bool connected);
void ui_set_recording(rec_lang_t lang);
void ui_show_text(const char *utf8);
void ui_show_status(const char *utf8);
/* The other person's language, appended to the status line as "<status> · <label>" (empty clears it).
 * At most 32 bytes of valid UTF-8; kept across reconnects. */
void ui_set_label(const char *utf8);
/* Speech level ring around the round screen, 0 = hidden, 1..100 = louder. Safe from any task. */
void ui_set_level(int percent);
/* Keeps the screen on (or wakes it). Safe from any task except LVGL callbacks. */
void ui_mark_activity(void);
/* Shows the sleep message and turns the panel off before deep sleep */
void ui_prepare_sleep(void);
void ui_prepare_power_off(void);
/* Temporarily replaces the status line (and wakes the screen) */
void ui_toast(const char *utf8, uint32_t ms);
/* Translator screen handle and wake override (ui.c) */
lv_obj_t *ui_translator_screen(void);
/* Wakes the panel and clears a double-tap screen-off (within ~250 ms) */
void ui_force_screen_on(void);
/* Blanks (true) or wakes (false) the panel like a double-tap. Safe from any task except LVGL callbacks. */
void ui_set_manual_screen_off(bool off);
/* True once the power-off / sleep message is up. Read it with the display lock held. */
bool ui_shutting_down(void);
/* pmu.c: true when external USB power (VBUS) is present; false if the PMU is unavailable */
bool pmu_usb_powered(void);

/* lock_ui.c: lock screen (logo, clock, battery) */
void lock_ui_init(void);
lv_obj_t *lock_ui_screen(void);
void lock_ui_set_face(bool visible);                /* LVGL task (screen timer): show/hide the face, run the clock tick */
/* A short non-interactive line on the lock screen for ms (lights the panel meanwhile, see lock_ui_notice_active).
 * Takes the LVGL lock (not from LVGL callbacks). */
void lock_ui_notice(const char *utf8, uint32_t ms);
bool lock_ui_notice_active(void);                   /* LVGL task / display lock held */

/* pair_ui.c: full-screen pairing code (pairing.h), numeric comparison with Sai / Đúng. show / close take the LVGL
 * lock (not from LVGL callbacks). The answer goes back as ble_link_pair_answer(conn, id, yes); the buttons ignore
 * taps for PAIR_ARM_MS after the code appears. */
void pair_ui_init(void);
void pair_ui_show(uint16_t conn, uint32_t id, uint32_t passkey);
void pair_ui_close(void);                           /* back to the screen the shell wants now */
bool pair_ui_active(void);                          /* the view is up: panel on, the shell leaves the screen alone */
uint32_t pair_ui_request_id(void);                  /* the request on screen, PAIR_ID_NONE (0) if none */

/* shell.c: modes, lock and inputs (see modes.h) */
void shell_start(void);
bool shell_post(modes_event_t ev);                  /* never blocks; safe from any task and LVGL callbacks; false: queue full */
void shell_snapshot(modes_t *out);                  /* current state, for the panel policy */

