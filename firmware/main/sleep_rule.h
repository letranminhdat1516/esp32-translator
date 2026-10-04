/*
 * Deep-sleep rule on battery (pure C, host-tested in firmware/test/test_sleep_rule.c; main.c applies it, and keeps
 * restamping idle_since on USB power, where the board never sleeps).
 * - The translator app's audio role or the Mac's Claude link: never.
 * - No link: SLEEP_RULE_IDLE_US after the last link went away.
 * - Only the iPhone notification link (ANCS, the app closed): SLEEP_RULE_NOTICES_IDLE_US after the later of the
 *   last link change and the last Claude notice shown. A 550 mAh battery would otherwise drain in under a day while
 *   the iPhone stays near; notices that arrive while the board sleeps are missed (a tap or BOOT wakes it).
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define SLEEP_RULE_IDLE_US         (3LL * 60 * 1000 * 1000)
#define SLEEP_RULE_NOTICES_IDLE_US (30LL * 60 * 1000 * 1000)
#define SLEEP_RULE_NEVER           0   /* idle_since: a link holds the board awake */

static inline bool sleep_rule_due(bool phone_role, bool claude_link, bool notices_link, int64_t idle_since_us,
                                  int64_t last_notice_us, int64_t now_us)
{
    if (phone_role || claude_link || idle_since_us == SLEEP_RULE_NEVER) {
        return false;
    }
    int64_t since = idle_since_us;
    int64_t limit = SLEEP_RULE_IDLE_US;
    if (notices_link) {
        if (last_notice_us > since) {
            since = last_notice_us;
        }
        limit = SLEEP_RULE_NOTICES_IDLE_US;
    }
    return now_us - since > limit;
}
