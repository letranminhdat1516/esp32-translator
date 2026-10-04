/* Device side of clock.h: system time via settimeofday (kept by the RTC timer, also across deep sleep). */
#include <string.h>
#include <sys/time.h>

#include "esp_attr.h"
#include "esp_log.h"

#include "clock.h"

static const char *TAG = "clock";

/* RTC memory: survives deep sleep (like the system time), cleared when the board loses power */
RTC_DATA_ATTR static bool s_known;
RTC_DATA_ATTR static int16_t s_offset_min;

bool clock_sync_text(const char *text)
{
    clock_sync_t s;
    if (!clock_parse(text, &s)) {
        ESP_LOGW(TAG, "ignoring bad time \"%.24s\"", text ? text : "");
        return false;
    }
    struct timeval tv = { .tv_sec = (time_t)s.unix_s, .tv_usec = 0 };
    settimeofday(&tv, NULL);
    s_offset_min = (int16_t)s.offset_min;
    s_known = true;
    ESP_LOGI(TAG, "time set: %lld, UTC offset %+d min", (long long)s.unix_s, s.offset_min);
    return true;
}

bool clock_now_hhmm(char out[6])
{
    if (!s_known) {
        memcpy(out, "--:--", 6);
        return false;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    clock_format_hhmm((int64_t)tv.tv_sec, s_offset_min, out);
    return true;
}
