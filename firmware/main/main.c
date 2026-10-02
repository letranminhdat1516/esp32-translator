#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "nvs_flash.h"

#include "app.h"

static const char *TAG = "main";

static QueueHandle_t s_cmd_queue;
static volatile rec_lang_t s_recording = REC_NONE;
static volatile bool s_connected;

void app_request_recording(rec_lang_t lang)
{
    xQueueSend(s_cmd_queue, &lang, 0);
}

rec_lang_t app_get_recording(void)
{
    return s_recording;
}

void app_on_connection_changed(bool connected)
{
    s_connected = connected;
    if (!connected) {
        app_request_recording(REC_NONE);
    }
    ui_set_connected(connected);
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_cmd_queue = xQueueCreate(8, sizeof(rec_lang_t));

    bsp_display_start();
    bsp_display_backlight_on();
    ui_init();

    ble_link_init();
    audio_in_start();

    /* Mọi yêu cầu bật/tắt thu âm (từ nút trên màn hình hoặc từ app) được xử lý tại đây */
    rec_lang_t lang;
    while (true) {
        if (xQueueReceive(s_cmd_queue, &lang, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        if (lang != REC_NONE && !s_connected) {
            ui_show_status("Chưa kết nối iPhone");
            continue;
        }
        if (lang == s_recording) {
            continue;
        }
        s_recording = lang;
        ESP_LOGI(TAG, "recording -> %d", lang);
        ui_set_recording(lang);
        ble_link_notify_control(lang);
    }
}
