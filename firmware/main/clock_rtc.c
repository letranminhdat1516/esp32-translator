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
        /* The text comes over BLE: log at most 24 bytes, non-printable ones as '?' */
        char shown[25];
        size_t n = 0;
        for (; text && text[n] && n < sizeof(shown) - 1; n++) {
            shown[n] = (text[n] >= 0x20 && text[n] < 0x7f) ? text[n] : '?';
        }
        shown[n] = '\0';
        ESP_LOGW(TAG, "ignoring bad time \"%s\"", shown);
        return false;
    }
    /* Zone before time, known last: the first reader after a first sync sees both */
    s_offset_min = (int16_t)s.offset_min;
    struct timeval tv = { .tv_sec = (time_t)s.unix_s, .tv_usec = 0 };
    settimeofday(&tv, NULL);
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
    if (!clock_plausible((int64_t)tv.tv_sec)) {
        memcpy(out, "--:--", 6);
        return false;
    }
    clock_format_hhmm((int64_t)tv.tv_sec, s_offset_min, out);
    return true;
}

bool clock_now_unix(int64_t *out)
{
    if (!s_known) {
        return false;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (!clock_plausible((int64_t)tv.tv_sec)) {
        return false;
    }
    *out = (int64_t)tv.tv_sec;
    return true;
}
