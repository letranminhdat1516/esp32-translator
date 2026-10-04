// firmware/test/test_link_pace.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_link_pace test_link_pace.c && /tmp/test_link_pace
#include <assert.h>
#include <stdio.h>
#include "link_pace.h"

#define SEC 1000000LL

static void waits_out_the_settle_window(void)
{
    /* ANCS ready 1.5 s after the connect: the app may still subscribe, wait the remaining 8.5 s */
    assert(link_pace_relax_wait_ms(100 * SEC, 100 * SEC + 1500000) == 8500);
    assert(link_pace_relax_wait_ms(100 * SEC, 100 * SEC) == LINK_PACE_SETTLE_MS);
}

static void relaxes_once_settled(void)
{
    assert(link_pace_relax_wait_ms(100 * SEC, 110 * SEC) == 0);
    assert(link_pace_relax_wait_ms(100 * SEC, 3600 * SEC) == 0);
}

static void never_waits_less_than_the_minimum(void)
{
    /* a fraction of a ms left is not "now", and not a busy 0-tick timer */
    assert(link_pace_relax_wait_ms(0, 10 * SEC - 1) == LINK_PACE_MIN_WAIT_MS);
    assert(link_pace_relax_wait_ms(0, 10 * SEC - 50000) == LINK_PACE_MIN_WAIT_MS);
}

static void stamp_after_now_waits_the_full_window(void)
{
    assert(link_pace_relax_wait_ms(10 * SEC + 5, 10 * SEC) == LINK_PACE_SETTLE_MS);
}

int main(void)
{
    waits_out_the_settle_window();
    relaxes_once_settled();
    never_waits_less_than_the_minimum();
    stamp_after_now_waits_the_full_window();
    printf("link_pace: all tests passed\n");
    return 0;
}
