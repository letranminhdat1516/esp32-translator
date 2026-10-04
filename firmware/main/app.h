#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Board microphone streaming state */
typedef enum {
    REC_NONE = 0,
    REC_EN   = 1,   /* board mic streaming (the other person, English) */
    REC_VI   = 2,   /* reserved */
} rec_lang_t;

/* main.c: every recording state change goes through this queue */
void app_request_recording(rec_lang_t lang);
rec_lang_t app_get_recording(void);
void app_on_connection_changed(bool connected);
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

/* audio_in.c */
void audio_in_start(void);

/* ui.c (takes the LVGL lock itself; do not call from LVGL callbacks) */
void ui_init(void);
void ui_set_connected(bool connected);
void ui_set_recording(rec_lang_t lang);
void ui_show_text(const char *utf8);
void ui_show_status(const char *utf8);
/* Keeps the screen on (or wakes it). Safe from any task except LVGL callbacks. */
void ui_mark_activity(void);
/* Shows the sleep message and turns the panel off before deep sleep */
void ui_prepare_sleep(void);
void ui_prepare_power_off(void);
/* Temporarily replaces the status line (and wakes the screen) */
void ui_toast(const char *utf8, uint32_t ms);
