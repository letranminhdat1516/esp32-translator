/*
 * AXP2101 power-management chip (I2C 0x34): battery gauge and the big PWR button.
 *
 * PWR button (polled from the PMU interrupt status, 10 Hz):
 *   single press  → show battery level
 *   double press  → switch app mode
 *   hold 3 s      → power off (on USB power, where the PMU would turn straight back on: deep sleep)
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
#define HOLD_OFF_MS      3000
#define DOUBLE_PRESS_MS  450

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

static void show_battery(void)
{
    pmu_battery_t b;
    char text[48];
    if (!pmu_battery(&b)) {
        ui_toast("Battery: unavailable", 3000);
    } else if (!b.present) {
        ui_toast("No battery (USB power)", 3000);
    } else {
        snprintf(text, sizeof(text), "Battery %d%%%s", b.percent, b.charging ? " · charging" : "");
        ui_toast(text, 3000);
    }
}

static void power_off(void)
{
    pmu_battery_t b = { 0 };
    pmu_battery(&b);
    if (b.usb_power) {
        ESP_LOGI(TAG, "hold: on USB power, deep sleep instead of power off");
        app_enter_deep_sleep();
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
    bool down = false;
    bool hold_fired = false;
    TickType_t down_at = 0;
    int pending_clicks = 0;
    TickType_t last_release = 0;

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
        TickType_t now = xTaskGetTickCount();

        uint8_t irq = 0;
        if (reg_read(REG_IRQ_STATUS2, &irq) == ESP_OK && irq) {
            reg_write(REG_IRQ_STATUS2, irq);
            if (irq & PKEY_PRESSED) {
                down = true;
                hold_fired = false;
                down_at = now;
            }
            if (irq & PKEY_RELEASED) {
                if (down && !hold_fired) {
                    pending_clicks++;
                    last_release = now;
                }
                down = false;
            }
        }

        if (down && !hold_fired && now - down_at >= pdMS_TO_TICKS(HOLD_OFF_MS)) {
            hold_fired = true;
            pending_clicks = 0;
            power_off();
        }

        if (pending_clicks > 0 && !down && now - last_release >= pdMS_TO_TICKS(DOUBLE_PRESS_MS)) {
            ui_mark_activity();
            if (pending_clicks >= 2) {
                ESP_LOGI(TAG, "PWR double press");
                app_switch_mode();
            } else {
                ESP_LOGI(TAG, "PWR single press");
                show_battery();
            }
            pending_clicks = 0;
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
