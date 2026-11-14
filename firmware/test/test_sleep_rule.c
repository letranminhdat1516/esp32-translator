// firmware/test/test_sleep_rule.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_sleep_rule test_sleep_rule.c && /tmp/test_sleep_rule
#include <assert.h>
#include <stdio.h>
#include "sleep_rule.h"

#define SEC 1000000LL
#define MIN (60 * SEC)

static void the_translator_link_never_sleeps(void)
{
    assert(!sleep_rule_due(true, 0, 999 * MIN));
    assert(!sleep_rule_due(true, 10 * MIN, 999 * MIN));
}

static void never_idle_never_sleeps(void)
{
    assert(!sleep_rule_due(false, SLEEP_RULE_NEVER, 999 * MIN));
}

static void no_link_sleeps_after_3_min(void)
{
    assert(!sleep_rule_due(false, 10 * MIN, 13 * MIN));
    assert(sleep_rule_due(false, 10 * MIN, 13 * MIN + 1));
}

static void clock_skew_is_not_idle(void)
{
    assert(!sleep_rule_due(false, 10 * MIN, 9 * MIN));
}

int main(void)
{
    the_translator_link_never_sleeps();
    never_idle_never_sleeps();
    no_link_sleeps_after_3_min();
    clock_skew_is_not_idle();
    printf("sleep_rule: all tests passed\n");
    return 0;
}
