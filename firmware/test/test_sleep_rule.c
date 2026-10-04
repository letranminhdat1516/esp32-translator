// firmware/test/test_sleep_rule.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_sleep_rule test_sleep_rule.c && /tmp/test_sleep_rule
#include <assert.h>
#include <stdio.h>
#include "sleep_rule.h"

#define SEC 1000000LL
#define MIN (60 * SEC)

static void a_translator_or_mac_link_never_sleeps(void)
{
    assert(!sleep_rule_due(true, false, false, 0, 0, 999 * MIN));
    assert(!sleep_rule_due(false, true, false, 0, 0, 999 * MIN));
    assert(!sleep_rule_due(true, true, true, 0, 0, 999 * MIN));
}

static void never_idle_never_sleeps(void)
{
    assert(!sleep_rule_due(false, false, false, SLEEP_RULE_NEVER, 0, 999 * MIN));
    assert(!sleep_rule_due(false, false, true, SLEEP_RULE_NEVER, 0, 999 * MIN));
}

static void no_link_sleeps_after_3_min(void)
{
    assert(!sleep_rule_due(false, false, false, 10 * MIN, 0, 13 * MIN));
    assert(sleep_rule_due(false, false, false, 10 * MIN, 0, 13 * MIN + 1));
}

static void notices_link_keeps_awake_30_min(void)
{
    /* idle since 10 min, no notice: 3 min is not enough, 30 min is */
    assert(!sleep_rule_due(false, false, true, 10 * MIN, 0, 13 * MIN + 1));
    assert(!sleep_rule_due(false, false, true, 10 * MIN, 0, 40 * MIN));
    assert(sleep_rule_due(false, false, true, 10 * MIN, 0, 40 * MIN + 1));
}

static void a_notice_restarts_the_30_min(void)
{
    /* idle since 10 min, a Claude notice shown at 35 min: awake until 65 min */
    assert(!sleep_rule_due(false, false, true, 10 * MIN, 35 * MIN, 41 * MIN));
    assert(!sleep_rule_due(false, false, true, 10 * MIN, 35 * MIN, 65 * MIN));
    assert(sleep_rule_due(false, false, true, 10 * MIN, 35 * MIN, 65 * MIN + 1));
}

static void a_notice_does_not_matter_without_the_notices_link(void)
{
    /* the link dropped (idle stamp at 50 min) after a notice at 49 min: the usual 3 min from the drop */
    assert(sleep_rule_due(false, false, false, 50 * MIN, 49 * MIN, 53 * MIN + 1));
    assert(!sleep_rule_due(false, false, false, 50 * MIN, 49 * MIN, 53 * MIN));
}

static void clock_skew_is_not_idle(void)
{
    assert(!sleep_rule_due(false, false, false, 10 * MIN, 0, 9 * MIN));
    assert(!sleep_rule_due(false, false, true, 10 * MIN, 20 * MIN, 15 * MIN));
}

int main(void)
{
    a_translator_or_mac_link_never_sleeps();
    never_idle_never_sleeps();
    no_link_sleeps_after_3_min();
    notices_link_keeps_awake_30_min();
    a_notice_restarts_the_30_min();
    a_notice_does_not_matter_without_the_notices_link();
    clock_skew_is_not_idle();
    printf("sleep_rule: all tests passed\n");
    return 0;
}
