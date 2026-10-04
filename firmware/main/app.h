#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"
#include "lvgl.h"
#include "modes.h"
#include "question.h"

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
/* Mac voice characteristic subscribed / left (NimBLE host task) */
void app_on_claude_voice_link(bool on);
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
bool ble_link_claude_connected(void);
bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);   /* CLAUDE_DECISION_* */
/* Any board -> Mac bytes (claude_proto.h encoders), at most CLAUDE_INPUT_MAX; false if no Mac */
bool ble_link_send_claude_input(const uint8_t *data, size_t len);
/* The same, retried briefly while the BLE buffers are full (a voice start: the link may still be settling) */
bool ble_link_send_claude_input_retry(const uint8_t *data, size_t len);
uint16_t ble_link_mac_mtu(void);                    /* negotiated ATT MTU of the Mac link, 0 without one */
/* Claude voice characteristic: the board mic to the Mac during a voice capture. Send from the audio task only.
 * ready: the Mac subscribed and the MTU fits one 20 ms frame per notification. */
bool ble_link_voice_ready(void);
uint16_t ble_link_voice_payload_max(void);
bool ble_link_send_voice(const uint8_t *data, uint16_t len);

/* ancs_client.c: iPhone notifications (ANCS), NimBLE host task: a link finished encrypting, a GATT notification
 * arrived (true when it was ANCS), a link went away */
void ancs_client_on_encrypted(uint16_t conn);
bool ancs_client_on_notify(uint16_t conn, uint16_t attr, const uint8_t *data, uint16_t len);
void ancs_client_on_disconnect(uint16_t conn);

/* audio_in.c */
void audio_in_start(void);
/* One voice capture at a time (voice_ui.c). start: false without the Mac voice link. stop: the audio task sends
 * its last packet, then the stop input, then calls voice_ui_capture_ended(). abort: stop streaming at once, no
 * stop input (the caller sent a cancel). */
bool audio_in_voice_start(uint32_t voice_id);
void audio_in_voice_stop(void);
void audio_in_voice_abort(void);

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
/* Translator screen handle and wake override (ui.c) */
lv_obj_t *ui_translator_screen(void);
/* Wakes the panel and clears a double-tap screen-off (within ~250 ms) */
void ui_force_screen_on(void);
/* Blanks (true) or wakes (false) the panel like a double-tap. Safe from any task except LVGL callbacks. */
void ui_set_manual_screen_off(bool off);
/* LVGL task (Claude / picker screen tap): ends a manual screen-off; the panel wakes within ~250 ms */
void ui_wake_from_tap(void);
/* True once the power-off / sleep message is up. Read it with the display lock held. */
bool ui_shutting_down(void);
/* pmu.c: true when external USB power (VBUS) is present; false if the PMU is unavailable */
bool pmu_usb_powered(void);

/* claude_ui.c: Claude companion screen */
void claude_ui_init(void);
lv_obj_t *claude_ui_screen(void);
/* Copies the text; takes the display lock. True when a request is now ready to show (take over the screen). */
bool claude_ui_on_message(const claude_msg_t *m);
void claude_ui_set_link(bool connected);
void claude_ui_set_touch_enabled(bool on);          /* LVGL task: answers ignore taps while the panel is dark */
bool claude_ui_pending(void);                       /* a request awaits an answer */
void claude_ui_refresh_session_locked(void);        /* display lock held: status badge + focused session view */
/* Every answer control (claude_ui.c, question_ui.c), LVGL task */
void claude_ui_note_press(void);                    /* call from LV_EVENT_PRESSED */
bool claude_ui_tap_armed(void);                     /* panel lit, press armed (dark: wakes); voice controls */
bool claude_ui_tap_allowed(void);                   /* tap_armed, a request pending, no voice overlay */
void claude_ui_rearm(void);                         /* new controls under the finger (page change) */
/* claude_ui.c: a spoken deny reason was applied (voice_ui.c): show "Denied", then restore */
void claude_ui_voice_denied_locked(void);
/* claude_ui.c: Send on the last question page (LVGL task): sends the answers and shows the result */
void claude_ui_question_send_locked(const uint8_t *answer, size_t len);

/* question_ui.c: AskUserQuestion pages on the Claude screen (display lock held for every call) */
void question_ui_init(lv_obj_t *scr, question_set_t *set);
void question_ui_show(void);                        /* page 1 of a complete set */
void question_ui_refresh(void);                     /* a shown page was resent: rebuild it (caller re-arms) */
void question_ui_hide(void);                        /* safe before init */
/* Use on the voice confirm screen: store the spoken Other answer of `page`, select it, redraw that page */
void question_ui_set_other(uint8_t page, const char *text);

/* voice_ui.c: voice capture overlay on the Claude screen (see the file header for the flow) */
void voice_ui_init(lv_obj_t *scr);                  /* after question_ui_init: on top of the question pages */
/* Display lock held (LVGL task): start a capture; purpose CLAUDE_VOICE_FOR_*, question = page (Other), target =
 * session handle or request id. True when the overlay is up (it may show an error). */
bool voice_ui_start_locked(uint8_t purpose, uint8_t question, uint32_t target);
void voice_ui_cancel_locked(void);                  /* drop any capture (sends cancel), hide the overlay */
void voice_ui_request_gone_locked(uint32_t id);     /* an Other / deny capture's request went away */
bool voice_ui_active_locked(void);                  /* the overlay is shown */
void voice_ui_on_message(const claude_msg_t *m);    /* kind 8, NimBLE host task; takes the lock */
void voice_ui_set_link(bool on);                    /* takes the lock */
void voice_ui_capture_ended(uint32_t id, bool stop_sent); /* audio task, after its stop input; takes the lock */
void voice_ui_level(int percent);                   /* audio task: level ring, 0 = hidden; takes the lock */

/* lock_ui.c: lock screen (logo, clock, battery) */
void lock_ui_init(void);
lv_obj_t *lock_ui_screen(void);
void lock_ui_set_face(bool visible);                /* LVGL task (screen timer): show/hide the face, run the clock tick */

/* picker_ui.c: Claude session picker; owns the session table */
void picker_ui_init(void);
lv_obj_t *picker_ui_screen(void);
void picker_ui_on_message(const claude_msg_t *m);   /* kinds 4-6; takes the display lock */
void picker_ui_set_link(bool connected);            /* takes the display lock; a lost link clears the rows */
void picker_ui_set_touch_enabled(bool on);          /* LVGL task */
const claude_session_t *picker_ui_focused_locked(void);
int picker_ui_badge_locked(void);

/* shell.c: modes, lock and inputs (see modes.h) */
void shell_start(void);
void shell_post(modes_event_t ev);                  /* never blocks; safe from any task and LVGL callbacks */
void shell_snapshot(modes_t *out);                  /* current state, for the panel policy */
void shell_resend_mode(void);                       /* tell the Mac the board mode again (Mac link up) */

/* chime.c: non-blocking notification chime on the speaker */
typedef enum { CHIME_REQUEST, CHIME_DONE } chime_t;
void chime_start(void);
void chime_play(chime_t kind);
