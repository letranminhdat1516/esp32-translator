// firmware/test/test_clock.c — build: cc -Wall -Werror -I../main -o /tmp/test_clock test_clock.c ../main/clock.c && /tmp/test_clock
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "clock.h"

static void parses_positive_and_negative_offsets(void)
{
    clock_sync_t s;
    assert(clock_parse("1759555200 420", &s) && s.unix_s == 1759555200 && s.offset_min == 420);
    assert(clock_parse("1759555200 -330", &s) && s.offset_min == -330);
    assert(clock_parse("1759555200 +345", &s) && s.offset_min == 345);
    assert(clock_parse("1759555200 0", &s) && s.offset_min == 0);
}

static void rejects_garbage(void)
{
    clock_sync_t s = { 42, 7 };
    const char *bad[] = {
        "", " ", "abc", "1759555200", "1759555200 ", "1759555200  420", " 1759555200 420",
        "1759555200 420\n", "1759555200 42x", "-1759555200 420", "1759555200 --5",
        "999999999 0",            /* 2001: older than any real phone clock */
        "4102444800 0",           /* 2100 */
        "1759555200 -721", "1759555200 841",
        "99999999999999999999 0", /* overflow */
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        assert(!clock_parse(bad[i], &s));
    }
    assert(!clock_parse(NULL, &s));
    assert(s.unix_s == 42 && s.offset_min == 7);   /* untouched on failure */
}

static void formats_local_time(void)
{
    char t[6];
    clock_format_hhmm(1759555200, 0, t);         /* 2025-10-04 05:20:00 UTC */
    assert(strcmp(t, "05:20") == 0);
    clock_format_hhmm(1759555200, 420, t);       /* Hanoi UTC+7 */
    assert(strcmp(t, "12:20") == 0);
    clock_format_hhmm(1759555200, -420, t);      /* UTC-7 crosses back over midnight */
    assert(strcmp(t, "22:20") == 0);
    clock_format_hhmm(1759555200, 345, t);       /* Nepal UTC+5:45 */
    assert(strcmp(t, "11:05") == 0);
    clock_format_hhmm(1759555200 + 18 * 3600 + 39 * 60 + 59, 0, t);   /* 23:59:59 */
    assert(strcmp(t, "23:59") == 0);
}

int main(void)
{
    parses_positive_and_negative_offsets();
    rejects_garbage();
    formats_local_time();
    puts("clock: all tests passed");
    return 0;
}
