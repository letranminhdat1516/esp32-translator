/* Simulator stand-in for the Waveshare BSP (and the FreeRTOS bits ui.c gets through it): one thread, so the
 * display lock is a no-op */
#pragma once
#include <stdbool.h>
#include <stdint.h>

static inline bool bsp_display_lock(uint32_t timeout_ms) { (void)timeout_ms; return true; }
static inline void bsp_display_unlock(void) {}
/* sim.c: 0 blanks the window like the dark AMOLED */
void bsp_display_brightness_set(int percent);

/* sim.c: keeps rendering while it waits (the power-off / sleep messages stay up this long) */
void vTaskDelay(uint32_t ms);
#define pdMS_TO_TICKS(ms) (ms)
