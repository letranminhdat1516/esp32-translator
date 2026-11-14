/*
 * Deep-sleep rule on battery (pure C, host-tested in firmware/test/test_sleep_rule.c; main.c applies it, and keeps
 * restamping idle_since on USB power, where the board never sleeps).
 * - The translator app's audio role: never.
 * - Otherwise: SLEEP_RULE_IDLE_US after the role went away (or since boot). A touch or BOOT wakes the board.
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define SLEEP_RULE_IDLE_US (3LL * 60 * 1000 * 1000)
#define SLEEP_RULE_NEVER   0   /* idle_since: a link holds the board awake */

static inline bool sleep_rule_due(bool phone_role, int64_t idle_since_us, int64_t now_us)
{
    if (phone_role || idle_since_us == SLEEP_RULE_NEVER) {
        return false;
    }
    return now_us - idle_since_us > SLEEP_RULE_IDLE_US;
}
