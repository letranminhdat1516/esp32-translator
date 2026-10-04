/*
 * AXP2101 power-management chip (I2C 0x34): battery gauge and the big PWR button.
 *
 * PWR button (polled from the PMU interrupt status, 10 Hz; counting in modes.c):
 *   x1 / x2 / x3  → shell.c: lock (on the lock: show the lock face) / translator / Claude mode
 *   hold 3 s      → power off (on USB power, where the PMU would turn straight back on: screen off)
 */
#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "app.h"

static const char *TAG = "pmu";

#define AXP2101_ADDR 0x34

#define REG_STATUS1        0x00   /* bit5 VBUS good, bit3 battery present */
#define REG_STATUS2        0x01   /* bits[6:5] 01 = charging */
#define REG_COMMON_CONFIG  0x10   /* bit0 = power off */
#define REG_GAUGE_CTRL     0x18   /* bit3 = fuel gauge enable */
#define REG_IRQ_STATUS2    0x49   /* power key events, write 1 to clear */
#define REG_BATTERY_PCT    0xA4

#define PKEY_PRESSED   0x02       /* measured: set on press */
#define PKEY_RELEASED  0x01       /* measured: set on release (with SHORT 0x08 for a short press) */

#define POLL_MS          100

static i2c_master_dev_handle_t s_pmu;

static esp_err_t reg_read(uint8_t reg, uint8_t *val)
{
    return i2c_master_transmit_receive(s_pmu, &reg, 1, val, 1, 50);
}

static esp_err_t reg_write(uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = { reg, val };
    return i2c_master_transmit(s_pmu, buf, 2, 50);
}

static esp_err_t reg_set_bits(uint8_t reg, uint8_t bits)
{
    uint8_t v;
    esp_err_t err = reg_read(reg, &v);
    return err == ESP_OK ? reg_write(reg, v | bits) : err;
}

bool pmu_battery(pmu_battery_t *out)
{
    uint8_t s1 = 0, s2 = 0, pct = 0;
    if (!s_pmu || reg_read(REG_STATUS1, &s1) != ESP_OK || reg_read(REG_STATUS2, &s2) != ESP_OK) {
        return false;
    }
    out->present = s1 & 0x08;
    out->usb_power = s1 & 0x20;
    out->charging = ((s2 >> 5) & 0x03) == 0x01;
    out->percent = -1;
    if (out->present && reg_read(REG_BATTERY_PCT, &pct) == ESP_OK && pct <= 100) {
        out->percent = pct;
    }
    return true;
}

bool pmu_usb_powered(void)
{
    pmu_battery_t b = { 0 };
    return pmu_battery(&b) && b.usb_power;
}

static void power_off(void)
{
    if (pmu_usb_powered()) {
        /* The PMU would power straight back on, and deep sleep would drop the USB port: just blank the screen */
        ESP_LOGI(TAG, "hold: on USB power, screen off instead of power off");
        ui_toast("On USB power: screen off", 1500);
        vTaskDelay(pdMS_TO_TICKS(1500));
        ui_set_manual_screen_off(true);
        return;
    }
    ESP_LOGI(TAG, "hold: power off");
    ui_prepare_power_off();
    reg_set_bits(REG_COMMON_CONFIG, 0x01);
    vTaskDelay(pdMS_TO_TICKS(1000));
    /* Still alive (PMU refused): fall back to deep sleep */
    app_enter_deep_sleep();
}

static void pmu_task(void *arg)
{
    static const modes_event_t PRESSES[] = { MODES_EV_PWR_1, MODES_EV_PWR_2, MODES_EV_PWR_3 };
    modes_clicks_t clicks = { 0 };

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
        bool pressed = false, released = false;
        uint8_t irq = 0;
        if (reg_read(REG_IRQ_STATUS2, &irq) == ESP_OK && irq) {
            reg_write(REG_IRQ_STATUS2, irq);
            pressed = irq & PKEY_PRESSED;
            released = irq & PKEY_RELEASED;
        }
        int r = modes_clicks_step(&clicks, pressed, released, (uint32_t)pdTICKS_TO_MS(xTaskGetTickCount()));
        if (r == MODES_CLICKS_HOLD) {
            power_off();
        } else if (r > 0) {
            ESP_LOGI(TAG, "PWR x%d", r);
            shell_post(PRESSES[r - 1]);
        }
    }
}

void pmu_start(void)
{
    i2c_master_bus_handle_t bus = bsp_i2c_get_handle();
    if (bus == NULL || i2c_master_probe(bus, AXP2101_ADDR, 50) != ESP_OK) {
        ESP_LOGW(TAG, "AXP2101 not found");
        return;
    }
    i2c_device_config_t cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AXP2101_ADDR,
        .scl_speed_hz = 400000,
    };
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus, &cfg, &s_pmu));
    reg_set_bits(REG_GAUGE_CTRL, 0x08);
    reg_write(REG_IRQ_STATUS2, 0xff);   /* drop stale key events from before boot */

    pmu_battery_t b;
    if (pmu_battery(&b)) {
        ESP_LOGI(TAG, "battery %s, %d%%, usb %d, charging %d",
                 b.present ? "present" : "absent", b.percent, b.usb_power, b.charging);
    }
    xTaskCreate(pmu_task, "pmu", 3072, NULL, 4, NULL);
}
