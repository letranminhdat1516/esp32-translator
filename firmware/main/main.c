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
#include "pairing.h"
#include "sleep_rule.h"

/* Dev builds (menuconfig: Live Translator) never deep sleep, like on USB power */
#if defined(CONFIG_TRANSLATOR_DEV_STAY_ON) && CONFIG_TRANSLATOR_DEV_STAY_ON
#define CONFIG_TRANSLATOR_DEV_STAY_ON_ENABLED 1
#else
#define CONFIG_TRANSLATOR_DEV_STAY_ON_ENABLED 0
#endif

static const char *TAG = "main";

/* Deep sleep on battery after 3 min without the translator app's link (sleep_rule.h); touching the screen or BOOT
 * wakes the board */
#define BOOT_BUTTON_GPIO          GPIO_NUM_0

static volatile int64_t s_disconnected_since;

static QueueHandle_t s_cmd_queue;
static volatile rec_lang_t s_recording = REC_NONE;
static volatile bool s_connected;
static volatile bool s_connected_seen;
/* Codes on screen that held deep sleep off since the app last connected (pairing.h): main task only */
static pair_sleep_t s_pair_sleep;
/* After a code that held sleep off closes, this much of the idle period is left at least (the app connects) */
#define PAIR_SLEEP_TAIL_US (30LL * 1000 * 1000)

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
    if (connected) {
        s_connected_seen = true;   /* the main task resets the pairing sleep-hold budget */
    }
    s_disconnected_since = connected ? 0 : esp_timer_get_time();
    ui_mark_activity();
    if (!connected) {
        app_request_recording(REC_NONE);
    }
    ui_set_connected(connected);
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
    lock_ui_init();
    pair_ui_init();
    shell_start();   /* before BLE and the PMU: they post events */

    ble_link_init();
    audio_in_start();
    pmu_start();

    /* All mic on/off requests (from the on-screen button or the app) are handled here */
    rec_lang_t lang;
    while (true) {
        if (xQueueReceive(s_cmd_queue, &lang, pdMS_TO_TICKS(1000)) != pdTRUE) {
            if (!s_connected && s_disconnected_since != 0) {
                /* Deep sleep drops the USB port (no reflash, no wake from the host): stay awake on USB power,
                 * and keep restarting the grace period so unplugging later still gives the full timeout */
                static bool usb_logged;
                if (s_connected_seen) {
                    s_connected_seen = false;
                    pair_sleep_reset(&s_pair_sleep);
                }
                if (pair_sleep_hold(&s_pair_sleep, pair_ui_request_id())) {
                    /* No sleep under a pairing code (each lasts at most 30 s, and only PAIR_SLEEP_HOLDS_MAX per idle
                     * period count). Leave at least PAIR_SLEEP_TAIL_US of the idle period for after it (time for
                     * the app to connect), without restarting the whole period: remote requests cannot keep the
                     * board awake */
                    int64_t floor = esp_timer_get_time() - SLEEP_RULE_IDLE_US + PAIR_SLEEP_TAIL_US;
                    if (s_disconnected_since < floor) {
                        s_disconnected_since = floor;
                    }
                } else if (pmu_usb_powered() || CONFIG_TRANSLATOR_DEV_STAY_ON_ENABLED) {
                    s_disconnected_since = esp_timer_get_time();
                    if (!usb_logged) {
                        ESP_LOGI(TAG, "on USB power: not sleeping while idle");
                        usb_logged = true;
                    }
                } else {
                    usb_logged = false;
                    if (sleep_rule_due(s_connected, s_disconnected_since, esp_timer_get_time())) {
                        app_enter_deep_sleep();
                    }
                }
            }
            continue;
        }
        if (lang != REC_NONE && !s_connected) {
            /* The app went silent (suspended after a call) on a link iOS kept: the tap brings the role back */
            if (!ble_link_wake_phone(lang)) {
                ui_show_status("iPhone not connected");
            }
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
