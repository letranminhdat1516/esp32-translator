/*
 * When the iPhone link may drop to the relaxed pace (pure C, host-tested in firmware/test/test_link_pace.c;
 * ble_link.c applies it). With encryption at connect, ANCS can be ready before the translator app subscribes or
 * writes: relaxing then and going fast again a moment later would stream the first ~2 s of audio at 210 ms. So a
 * link relaxes only LINK_PACE_SETTLE_MS after it connected or became the waiting audio link, and only while it
 * still carries ANCS alone (ble_link.c checks the roles).
 */
#pragma once
#include <stdint.h>

#define LINK_PACE_SETTLE_MS   10000u
#define LINK_PACE_MIN_WAIT_MS 100u   /* never re-check sooner: a timer tick may round a few ms down to "now" */

/* 0: relax now. Otherwise: ms until the settle window ends (at least LINK_PACE_MIN_WAIT_MS). */
static inline uint32_t link_pace_relax_wait_ms(int64_t settle_from_us, int64_t now_us)
{
    int64_t since = now_us - settle_from_us;
    if (since < 0) {
        since = 0;
    }
    if (since >= (int64_t)LINK_PACE_SETTLE_MS * 1000) {
        return 0;
    }
    int64_t left_ms = ((int64_t)LINK_PACE_SETTLE_MS * 1000 - since + 999) / 1000;
    return left_ms < LINK_PACE_MIN_WAIT_MS ? LINK_PACE_MIN_WAIT_MS : (uint32_t)left_ms;
}
