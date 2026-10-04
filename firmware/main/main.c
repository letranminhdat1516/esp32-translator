#include <stdio.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "driver/rtc_io.h"
#include "esp_log.h"
#include "esp_pm.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "nvs_flash.h"

#include "app.h"
#include "clock.h"

static const char *TAG = "main";

/* Deep sleep after this long without an iPhone; touching the screen wakes the board */
#define SLEEP_AFTER_DISCONNECT_US (3LL * 60 * 1000 * 1000)
#define BOOT_BUTTON_GPIO          GPIO_NUM_0

static volatile int64_t s_disconnected_since;

static QueueHandle_t s_cmd_queue;
static volatile rec_lang_t s_recording = REC_NONE;
static volatile bool s_connected;
static volatile bool s_claude_link;

void app_request_recording(rec_lang_t lang)
{
    xQueueSend(s_cmd_queue, &lang, 0);
}

rec_lang_t app_get_recording(void)
{
    return s_recording;
}

void app_on_speech_activity(void)
{
    ui_mark_activity();
}

void app_on_connection_changed(bool connected)
{
    s_connected = connected;
    s_disconnected_since = connected ? 0 : esp_timer_get_time();
    ui_mark_activity();
    if (!connected) {
        app_request_recording(REC_NONE);
    }
    ui_set_connected(connected);
}

void app_on_claude_link(bool connected)
{
    s_claude_link = connected;
    if (!connected && !s_connected) {
        s_disconnected_since = esp_timer_get_time();
    }
    ESP_LOGI(TAG, "Claude link %s", connected ? "up" : "down");
    claude_ui_set_link(connected);
    ui_mark_activity();
}

/* msg points to a static buffer overwritten by the next BLE write: consume it synchronously */
void app_on_claude_message(const claude_msg_t *msg)
{
    ESP_LOGI(TAG, "claude msg kind=%d id=%lu", msg->kind, (unsigned long)msg->id);
    switch (msg->kind) {
    case CLAUDE_PERMISSION:
        claude_ui_on_message(msg);
        claude_ui_present_request();   /* takes over the screen; the previous one comes back afterwards */
        ui_force_screen_on();
        chime_play(CHIME_REQUEST);
        break;
    case CLAUDE_FINISHED:
        claude_ui_on_message(msg);
        {
            /* "Claude finished: <project>" (project = first line). Host task only, so a static buffer is fine. */
            static char toast[CLAUDE_TEXT_MAX + 32];
            const char *nl = strchr(msg->text, '\n');
            int project_len = nl ? (int)(nl - msg->text) : (int)strlen(msg->text);
            snprintf(toast, sizeof(toast), "Claude finished: %.*s", project_len, msg->text);
            ui_toast(toast, 3000);
        }
        chime_play(CHIME_DONE);
        break;
    case CLAUDE_CANCEL:
        claude_ui_on_message(msg);
        break;
    case CLAUDE_TIME:
        clock_sync_text(msg->text);
        break;
    default:
        ESP_LOGW(TAG, "ignoring unknown claude kind %d", msg->kind);
        break;
    }
}

static void enable_power_management(void)
{
    /* The mic I2S keeps the APB clock at max, so light sleep is off; the CPU still scales 160 <-> 80 MHz.
     * BLE modem sleep (sdkconfig) turns the radio off between connection events. */
    esp_pm_config_t pm = {
        .max_freq_mhz = 160,
        .min_freq_mhz = 80,
        .light_sleep_enable = false,
    };
    esp_err_t err = esp_pm_configure(&pm);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "power management unavailable: %s", esp_err_to_name(err));
    }
}

void app_switch_mode(void)
{
    claude_ui_toggle();
    ui_mark_activity();
}

void app_enter_deep_sleep(void)
{
    ESP_LOGI(TAG, "entering deep sleep (touch the screen or press BOOT to wake)");
    ui_prepare_sleep();
    /* Touch controller INT and the BOOT button both pull low */
    const uint64_t mask = (1ULL << BSP_LCD_TOUCH_INT) | (1ULL << BOOT_BUTTON_GPIO);
    rtc_gpio_pullup_en(BSP_LCD_TOUCH_INT);
    rtc_gpio_pulldown_dis(BSP_LCD_TOUCH_INT);
    rtc_gpio_pullup_en(BOOT_BUTTON_GPIO);
    rtc_gpio_pulldown_dis(BOOT_BUTTON_GPIO);
    esp_sleep_enable_ext1_wakeup_io(mask, ESP_EXT1_WAKEUP_ANY_LOW);
    esp_deep_sleep_start();
}

void app_main(void)
{
    if (esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT1) {
        ESP_LOGI(TAG, "woke from deep sleep");
    }
    enable_power_management();
    s_disconnected_since = esp_timer_get_time();

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_cmd_queue = xQueueCreate(8, sizeof(rec_lang_t));

    bsp_display_start();
    /* The panel shares the SPI bus with LVGL flushes: talk to it only under the display lock */
    bsp_display_lock((uint32_t)-1);
    bsp_display_backlight_on();
    bsp_display_brightness_set(100);
    bsp_display_unlock();
    ui_init();
    claude_ui_init();

    chime_start();   /* before the other audio users: the BSP audio init is not thread-safe */
    ble_link_init();
    audio_in_start();
    pmu_start();

    /* All mic on/off requests (from the on-screen button or the app) are handled here */
    rec_lang_t lang;
    while (true) {
        if (xQueueReceive(s_cmd_queue, &lang, pdMS_TO_TICKS(1000)) != pdTRUE) {
            if (!s_connected && !s_claude_link && s_disconnected_since != 0) {
                /* Deep sleep drops the USB port (no reflash, no wake from the host): stay awake on USB power,
                 * and keep restarting the grace period so unplugging later still gives the full timeout */
                static bool usb_logged;
                if (pmu_usb_powered()) {
                    s_disconnected_since = esp_timer_get_time();
                    if (!usb_logged) {
                        ESP_LOGI(TAG, "on USB power: not sleeping while idle");
                        usb_logged = true;
                    }
                } else {
                    usb_logged = false;
                    if (esp_timer_get_time() - s_disconnected_since > SLEEP_AFTER_DISCONNECT_US) {
                        app_enter_deep_sleep();
                    }
                }
            }
            continue;
        }
        if (lang != REC_NONE && !s_connected) {
            ui_show_status("iPhone not connected");
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
