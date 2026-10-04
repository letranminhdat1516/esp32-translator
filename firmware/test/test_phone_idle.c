// firmware/test/test_phone_idle.c — build: cc -Wall -Werror -I../main -o /tmp/test_phone_idle test_phone_idle.c && /tmp/test_phone_idle
#include <assert.h>
#include <stdio.h>
#include "phone_idle.h"

#define SEC 1000000LL

static void fresh_write_waits_the_full_timeout(void)
{
    assert(phone_idle_check_ms(100 * SEC, 100 * SEC) == PHONE_IDLE_TIMEOUT_MS);
}

static void waits_only_the_time_left(void)
{
    assert(phone_idle_check_ms(0, 20 * SEC) == 40000);
    assert(phone_idle_check_ms(0, 59 * SEC) == PHONE_IDLE_MIN_CHECK_MS);
    /* a fraction of a ms left rounds up, never to 0 (0 means "drop now") */
    assert(phone_idle_check_ms(0, 60 * SEC - 1) == PHONE_IDLE_MIN_CHECK_MS);
}

static void keepalives_every_20s_never_expire(void)
{
    int64_t last = 0;
    int64_t check = PHONE_IDLE_TIMEOUT_MS * 1000LL;   /* armed at promotion (t = 0) */
    for (int64_t t = 0; t <= 3600 * SEC; t += SEC) {
        if (t % (20 * SEC) == 0) {
            last = t;
        }
        if (t == check) {
            uint32_t ms = phone_idle_check_ms(last, t);
            assert(ms != 0);
            check = t + ms * 1000LL;
        }
    }
}

static void silence_drops_at_60s(void)
{
    assert(phone_idle_check_ms(0, 60 * SEC) == 0);
    assert(phone_idle_check_ms(0, 3600 * SEC) == 0);
    /* last keepalive at 40 s, app killed: the 60 s check re-arms for 40 s, then drops at 100 s */
    assert(phone_idle_check_ms(40 * SEC, 60 * SEC) == 40000);
    assert(phone_idle_check_ms(40 * SEC, 100 * SEC) == 0);
}

static void write_after_now_counts_as_alive(void)
{
    assert(phone_idle_check_ms(10 * SEC + 5, 10 * SEC) == PHONE_IDLE_TIMEOUT_MS);
}

static void keepalive_byte_is_not_a_mic_state(void)
{
    assert(PHONE_CTRL_KEEPALIVE > 2);   /* REC_VI (app.h) is the highest mic state */
}

int main(void)
{
    fresh_write_waits_the_full_timeout();
    waits_only_the_time_left();
    keepalives_every_20s_never_expire();
    silence_drops_at_60s();
    write_after_now_counts_as_alive();
    keepalive_byte_is_not_a_mic_state();
    printf("test_phone_idle: all passed\n");
    return 0;
}
