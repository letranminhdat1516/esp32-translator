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
#include "freertos/semphr.h"
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
    "session picked", "iPhone notice", "iPhone notice done",
};
_Static_assert(sizeof EV_NAMES / sizeof EV_NAMES[0] == MODES_EV_NOTICE_DONE + 1, "EV_NAMES out of sync");
_Static_assert(CLAUDE_BOARD_OTHER == 0 && CLAUDE_BOARD_CLAUDE == 1 && CLAUDE_BOARD_PICKER == 2,
               "modes_report() returns CLAUDE_BOARD_* values");

/* Last board mode the Mac was told (modes_report_due); MODES_REPORT_UNSENT = tell it again. Session rows flow
 * only while it is Claude or picker. Read and written under s_mux together with s_state; s_report_lock keeps a
 * whole report (decide, then notify) in order between the shell task and the NimBLE host task (link-up). */
static int s_reported = MODES_REPORT_UNSENT;
static SemaphoreHandle_t s_report_lock;
static StaticSemaphore_t s_report_lock_buf;

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

/* Shell task or NimBLE host task, never with the display lock held and never from LVGL callbacks or timers
 * (it may wait for the other task's report). again: the Mac link just came up, tell it whatever the mode. */
static void report_mode(bool again)
{
    if (s_report_lock == NULL) {
        return;   /* before shell_start */
    }
    xSemaphoreTake(s_report_lock, portMAX_DELAY);
    taskENTER_CRITICAL(&s_mux);
    if (again) {
        s_reported = MODES_REPORT_UNSENT;
    }
    bool due = modes_report_due(&s_reported, &s_state);
    int mode = s_reported;
    taskEXIT_CRITICAL(&s_mux);
    if (due) {
        uint8_t buf[CLAUDE_INPUT_MAX];
        size_t n = claude_encode_mode((uint8_t)mode, buf);
        if (ble_link_send_claude_input(buf, n)) {
            ESP_LOGI(TAG, "told the Mac: board mode %d", mode);
        } else {
            /* No Mac subscribed, or the notify failed: tell it on the next change or when the link comes up */
            taskENTER_CRITICAL(&s_mux);
            s_reported = MODES_REPORT_UNSENT;
            taskEXIT_CRITICAL(&s_mux);
        }
    }
    xSemaphoreGive(s_report_lock);
}

void shell_resend_mode(void)
{
    report_mode(true);
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
    case SCREEN_PHONE:
        return phone_ui_screen();
    default:
        return ui_translator_screen();
    }
}

static void shell_task(void *arg)
{
    QueueHandle_t queue = arg;   /* s_queue may not be published yet when this task first runs */
    modes_event_t ev;
    while (xQueueReceive(queue, &ev, portMAX_DELAY) == pdTRUE) {
        int64_t now = esp_timer_get_time();
        modes_t next;
        taskENTER_CRITICAL(&s_mux);
        bool wake = modes_handle(&s_state, ev, now);
        next = s_state;
        taskEXIT_CRITICAL(&s_mux);

        ESP_LOGI(TAG, "%s -> mode %d%s%s", EV_NAMES[ev], (int)next.mode, next.locked ? ", locked" : "",
                 next.urgent ? ", request shown" : "");
        /* Load first, then wake: the panel never lights on the previous screen. Loading the Claude screen
         * runs its SCREEN_LOADED handler here, under this lock (it re-arms Allow/Deny). */
        lv_obj_t *target = screen_obj(modes_screen(&next));
        bsp_display_lock((uint32_t)-1);
        bool shutting_down = ui_shutting_down();   /* the power-off / sleep message owns the screen */
        if (!shutting_down && lv_screen_active() != target) {
            lv_screen_load(target);
        }
        bsp_display_unlock();
        if (wake && !shutting_down) {
            ui_force_screen_on();
        }
        report_mode(false);   /* after every input, not only waking ones: locking changes the report too */
        /* Debug: shell task stack headroom (bytes never used) after a screen load */
        ESP_LOGI(TAG, "stack headroom shell: %u bytes", (unsigned)uxTaskGetStackHighWaterMark(NULL));
    }
}

void shell_start(void)
{
    modes_init(&s_state);
    s_report_lock = xSemaphoreCreateMutexStatic(&s_report_lock_buf);
    /* Fail safe without a queue or task: shell_post drops inputs, the board stays unlocked on the translator
     * and the panel keeps its usual idle policy (MODES_PANEL_AUTO) */
    QueueHandle_t q = xQueueCreate(16, sizeof(modes_event_t));
    if (q == NULL) {
        ESP_LOGE(TAG, "no memory for the input queue: buttons and lock disabled");
        return;
    }
    if (xTaskCreate(shell_task, "shell", 4096, q, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "no memory for the shell task: buttons and lock disabled");
        vQueueDelete(q);
        return;
    }
    s_queue = q;

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
