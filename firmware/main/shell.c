/*
 * Board shell: turns button and gesture inputs into mode changes (modes.c) and applies them: which screen
 * is loaded and whether the panel must wake. The panel power policy itself is read by ui.c's screen timer
 * (shell_snapshot + modes_panel).
 * Inputs: PWR x1/x2/x3 from pmu.c, BOOT (GPIO0, active low) by interrupt here, lock-screen taps from
 * lock_ui.c, Claude requests from main.c / claude_ui.c. shell_post() never blocks and is safe from any task,
 * LVGL callbacks and timers included; only the shell task touches the display lock.
 */
#include "bsp/esp-bsp.h"
#include "driver/gpio.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "app.h"

static const char *TAG = "shell";

#define BOOT_GPIO        GPIO_NUM_0
#define BOOT_DEBOUNCE_US (250 * 1000)   /* contact bounce; a repeated BOOT x1 is harmless anyway */

static QueueHandle_t s_queue;
static modes_t s_state;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

static const char *const EV_NAMES[] = {
    "PWR x1", "PWR x2", "PWR x3", "BOOT x1", "tap x1", "tap x2", "Claude request", "Claude request done",
};

void shell_post(modes_event_t ev)
{
    if (s_queue) {
        xQueueSend(s_queue, &ev, 0);
    }
}

void shell_snapshot(modes_t *out)
{
    taskENTER_CRITICAL(&s_mux);
    *out = s_state;
    taskEXIT_CRITICAL(&s_mux);
}

static void IRAM_ATTR boot_isr(void *arg)
{
    static int64_t last_us;
    int64_t now = esp_timer_get_time();
    if (now - last_us < BOOT_DEBOUNCE_US) {
        return;
    }
    last_us = now;
    modes_event_t ev = MODES_EV_BOOT_1;
    BaseType_t woken = pdFALSE;
    xQueueSendFromISR(s_queue, &ev, &woken);
    if (woken) {
        portYIELD_FROM_ISR();
    }
}

static lv_obj_t *screen_obj(board_screen_t s)
{
    switch (s) {
    case SCREEN_CLAUDE:
        return claude_ui_screen();
    case SCREEN_PICKER:
        return picker_ui_screen();
    case SCREEN_LOCK:
        return lock_ui_screen();
    default:
        return ui_translator_screen();
    }
}

static void shell_task(void *arg)
{
    modes_event_t ev;
    while (xQueueReceive(s_queue, &ev, portMAX_DELAY) == pdTRUE) {
        int64_t now = esp_timer_get_time();
        modes_t next;
        taskENTER_CRITICAL(&s_mux);
        bool wake = modes_handle(&s_state, ev, now);
        next = s_state;
        taskEXIT_CRITICAL(&s_mux);

        ESP_LOGI(TAG, "%s -> mode %d%s%s", EV_NAMES[ev], (int)next.mode, next.locked ? ", locked" : "",
                 next.urgent ? ", request shown" : "");
        if (wake) {
            ui_force_screen_on();
        }
        lv_obj_t *target = screen_obj(modes_screen(&next));
        bsp_display_lock((uint32_t)-1);
        if (lv_screen_active() != target) {
            lv_screen_load(target);
        }
        bsp_display_unlock();
    }
}

void shell_start(void)
{
    modes_init(&s_state);
    s_queue = xQueueCreate(16, sizeof(modes_event_t));
    xTaskCreate(shell_task, "shell", 3072, NULL, 5, NULL);

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << BOOT_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .intr_type = GPIO_INTR_NEGEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&io));
    esp_err_t err = gpio_install_isr_service(0);   /* the touch driver may have installed it already */
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "BOOT button unavailable: %s", esp_err_to_name(err));
        return;
    }
    ESP_ERROR_CHECK(gpio_isr_handler_add(BOOT_GPIO, boot_isr, NULL));
}
