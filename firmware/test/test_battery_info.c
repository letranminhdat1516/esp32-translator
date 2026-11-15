// firmware/test/test_battery_info.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_battery_info test_battery_info.c && /tmp/test_battery_info
#include <assert.h>
#include <stdio.h>
#include "battery_info.h"

static void percent_and_flags(void)
{
    uint8_t b[2];
    battery_info_encode(true, 82, true, true, b);
    assert(b[0] == 82 && b[1] == (BATTERY_PRESENT | BATTERY_CHARGING | BATTERY_USB));
    battery_info_encode(true, 5, false, false, b);
    assert(b[0] == 5 && b[1] == BATTERY_PRESENT);
}

static void unknown_percent_is_0xff(void)
{
    uint8_t b[2];
    battery_info_encode(true, -1, false, true, b);
    assert(b[0] == BATTERY_PERCENT_UNKNOWN && b[1] == (BATTERY_PRESENT | BATTERY_USB));
    battery_info_encode(true, 101, false, false, b);
    assert(b[0] == BATTERY_PERCENT_UNKNOWN);
}

static void no_battery_reports_no_percent(void)
{
    uint8_t b[2];
    battery_info_encode(false, 77, false, true, b);
    assert(b[0] == BATTERY_PERCENT_UNKNOWN && b[1] == BATTERY_USB);
}

int main(void)
{
    percent_and_flags();
    unknown_percent_is_0xff();
    no_battery_reports_no_percent();
    puts("test_battery_info: ok");
    return 0;
}
