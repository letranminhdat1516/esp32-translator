#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Ai đang nói, tức là app iPhone cần nhận dạng ngôn ngữ nào */
typedef enum {
    REC_NONE = 0,
    REC_EN   = 1,   /* người đối diện nói tiếng Anh */
    REC_VI   = 2,   /* mình nói tiếng Việt */
} rec_lang_t;

/* main.c: mọi thay đổi trạng thái thu âm đi qua hàng đợi này */
void app_request_recording(rec_lang_t lang);
rec_lang_t app_get_recording(void);
void app_on_connection_changed(bool connected);

/* ble_link.c */
void ble_link_init(void);
bool ble_link_audio_ready(void);
uint16_t ble_link_payload_max(void);
bool ble_link_send_audio(const uint8_t *data, uint16_t len);
void ble_link_notify_control(uint8_t state);

/* audio_in.c */
void audio_in_start(void);

/* ui.c (tự lấy khoá LVGL, không gọi từ callback LVGL) */
void ui_init(void);
void ui_set_connected(bool connected);
void ui_set_recording(rec_lang_t lang);
void ui_show_text(const char *utf8);
void ui_show_status(const char *utf8);
