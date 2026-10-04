// firmware/test/test_claude_link.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_link test_claude_link.c ../main/claude_link.c && /tmp/test_claude_link
#include <assert.h>
#include <stdio.h>
#include "claude_link.h"

#define MAC   1
#define PHONE 2
#define OTHER 3
#define MIN_MTU 168

static claude_links_t fresh(void)
{
    claude_links_t l;
    claude_links_init(&l);
    return l;
}

static claude_link_state_t st(const claude_links_t *l)
{
    return claude_links_state(l, MIN_MTU);
}

static void mac_needs_subscription_and_hello(void)
{
    claude_links_t l = fresh();
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));          /* not subscribed: refused */
    assert(!claude_links_may_write(&l, MAC));
    assert(claude_links_answer(&l, MAC, true));
    assert(claude_links_may_write(&l, MAC));
    assert(st(&l).active == CLAUDE_CONN_NONE);                       /* subscribed is not enough */
    assert(claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));
    claude_link_state_t s = st(&l);
    assert(s.active == MAC && !s.relayed && !s.voice);
}

static void restored_subscription_without_hello_is_nothing(void)
{
    /* iOS reconnects for ANCS without the app: NimBLE restores the bonded answer CCCD on encryption */
    claude_links_t l = fresh();
    claude_links_answer(&l, PHONE, true);
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void relay_only_on_the_phone_link(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, OTHER, true);
    assert(!claude_links_hello(&l, OTHER, CLAUDE_ROLE_RELAY));      /* no translator audio role */
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    assert(claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY));
    claude_link_state_t s = st(&l);
    assert(s.active == PHONE && s.relayed);
}

static void mac_never_on_the_phone_link(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    assert(!claude_links_hello(&l, PHONE, CLAUDE_ROLE_MAC));
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void mac_preferred_over_relay(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC);
    claude_links_disconnected(&l, MAC);                              /* the Mac walks out of range */
    claude_link_state_t s = st(&l);
    assert(s.active == PHONE && s.relayed);
    claude_links_answer(&l, MAC, true);                              /* back: a new hello makes it active again */
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC);
}

static void second_role_holder_is_refused(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    claude_links_answer(&l, OTHER, true);
    assert(!claude_links_hello(&l, OTHER, CLAUDE_ROLE_MAC));
    assert(claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));            /* the same hello again is harmless */
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_RELAY));         /* a different one is refused */
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_NONE));
    assert(st(&l).active == MAC);
}

static void unsubscribe_clears_the_role(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    claude_links_answer(&l, MAC, false);
    assert(st(&l).active == CLAUDE_CONN_NONE);
    assert(!claude_links_may_write(&l, MAC));
    claude_links_answer(&l, MAC, true);                              /* resubscribing needs a new hello */
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void phone_role_lost_drops_the_relay(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_phone(&l, CLAUDE_CONN_NONE);                        /* the translator app closed its audio */
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void voice_follows_the_active_link_and_its_mtu(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_voice(&l, PHONE, true);
    assert(!st(&l).voice);                                           /* default MTU 23 */
    claude_links_mtu(&l, PHONE, 185);
    assert(st(&l).voice && st(&l).mtu == 185);
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC && !st(&l).voice);                   /* the Mac has not subscribed to voice */
    claude_links_mtu(&l, MAC, 247);
    claude_links_voice(&l, MAC, true);
    assert(st(&l).voice && st(&l).mtu == 247);
}

static void mtu_before_subscription_is_kept(void)
{
    claude_links_t l = fresh();
    claude_links_mtu(&l, MAC, 247);                                  /* MTU exchange comes first */
    claude_links_answer(&l, MAC, true);
    claude_links_voice(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).voice);
}

static void slots_full_is_refused(void)
{
    claude_links_t l = fresh();
    assert(claude_links_answer(&l, 10, true));
    assert(claude_links_answer(&l, 11, true));
    assert(claude_links_answer(&l, 12, true));
    assert(!claude_links_answer(&l, 13, true));
    assert(!claude_links_may_write(&l, 13));
    assert(claude_links_answer(&l, 13, false));                      /* turning off an unknown link is fine */
    claude_links_disconnected(&l, 10);
    assert(claude_links_answer(&l, 13, true));                       /* the slot came back */
    assert(claude_links_slot(&l, 13) >= 0 && claude_links_slot(&l, 10) == -1);
}

static void link_events_for_a_switch_with_voice(void)
{
    claude_link_ev_t ev[3];
    claude_link_state_t none = { .active = CLAUDE_CONN_NONE };
    claude_link_state_t mac_voice = { .active = MAC, .voice = true, .mtu = 247 };
    claude_link_state_t relay_voice = { .active = PHONE, .relayed = true, .voice = true, .mtu = 185 };
    claude_link_state_t relay_plain = { .active = PHONE, .relayed = true, .mtu = 185 };

    assert(claude_link_events(none, none, ev) == 0);
    assert(claude_link_events(none, mac_voice, ev) == 2 && ev[0] == CLAUDE_LINK_EV_UP && ev[1] == CLAUDE_LINK_EV_VOICE_ON);
    /* Mac → relay: down (ends voice), up, voice again on the new link */
    assert(claude_link_events(mac_voice, relay_voice, ev) == 3);
    assert(ev[0] == CLAUDE_LINK_EV_DOWN && ev[1] == CLAUDE_LINK_EV_UP && ev[2] == CLAUDE_LINK_EV_VOICE_ON);
    assert(claude_link_events(relay_voice, relay_plain, ev) == 1 && ev[0] == CLAUDE_LINK_EV_VOICE_OFF);
    assert(claude_link_events(relay_plain, relay_voice, ev) == 1 && ev[0] == CLAUDE_LINK_EV_VOICE_ON);
    assert(claude_link_events(relay_voice, none, ev) == 1 && ev[0] == CLAUDE_LINK_EV_DOWN);
    /* an MTU change that keeps voice on is no event */
    claude_link_state_t relay_voice_bigger = relay_voice;
    relay_voice_bigger.mtu = 247;
    assert(claude_link_events(relay_voice, relay_voice_bigger, ev) == 0);
}

int main(void)
{
    mac_needs_subscription_and_hello();
    restored_subscription_without_hello_is_nothing();
    relay_only_on_the_phone_link();
    mac_never_on_the_phone_link();
    mac_preferred_over_relay();
    second_role_holder_is_refused();
    unsubscribe_clears_the_role();
    phone_role_lost_drops_the_relay();
    voice_follows_the_active_link_and_its_mtu();
    mtu_before_subscription_is_kept();
    slots_full_is_refused();
    link_events_for_a_switch_with_voice();
    puts("claude_link: all tests passed");
    return 0;
}
