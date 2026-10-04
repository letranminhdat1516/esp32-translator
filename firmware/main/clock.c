#include "clock.h"

#include <stdlib.h>

#define CLOCK_MIN_UNIX 1700000000LL   /* 2023-11-14 */
#define CLOCK_MAX_UNIX 4102444800LL   /* 2100-01-01 */
#define CLOCK_MIN_OFFSET (-12 * 60)
#define CLOCK_MAX_OFFSET (14 * 60)

static bool parse_int(const char **p, bool allow_sign, long long *out)
{
    const char *s = *p;
    bool neg = false;
    if (allow_sign && (*s == '-' || *s == '+')) {
        neg = *s == '-';
        s++;
    }
    if (*s < '0' || *s > '9') {
        return false;
    }
    long long v = 0;
    int digits = 0;
    while (*s >= '0' && *s <= '9') {
        if (++digits > 12) {
            return false;
        }
        v = v * 10 + (*s - '0');
        s++;
    }
    *out = neg ? -v : v;
    *p = s;
    return true;
}

bool clock_parse(const char *text, clock_sync_t *out)
{
    if (!text) {
        return false;
    }
    const char *p = text;
    long long secs, offset;
    if (!parse_int(&p, false, &secs) || *p++ != ' ' || !parse_int(&p, true, &offset) || *p != '\0') {
        return false;
    }
    if (secs < CLOCK_MIN_UNIX || secs >= CLOCK_MAX_UNIX || offset < CLOCK_MIN_OFFSET || offset > CLOCK_MAX_OFFSET) {
        return false;
    }
    out->unix_s = secs;
    out->offset_min = (int)offset;
    return true;
}

void clock_format_hhmm(int64_t unix_s, int offset_min, char out[6])
{
    int64_t local = unix_s + (int64_t)offset_min * 60;
    int64_t sod = local % 86400;
    if (sod < 0) {
        sod += 86400;
    }
    int h = (int)(sod / 3600), m = (int)(sod % 3600 / 60);
    out[0] = (char)('0' + h / 10);
    out[1] = (char)('0' + h % 10);
    out[2] = ':';
    out[3] = (char)('0' + m / 10);
    out[4] = (char)('0' + m % 10);
    out[5] = '\0';
}
