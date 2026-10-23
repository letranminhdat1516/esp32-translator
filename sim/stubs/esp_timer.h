/* Simulator stand-in: monotonic microseconds (sim.c) */
#pragma once
#include <stdint.h>
int64_t esp_timer_get_time(void);
