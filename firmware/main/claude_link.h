/*
 * Which BLE connection is the board's Claude link (pure, host-tested in firmware/test/test_claude_link.c).
 *
 * A connection gets a role only from its hello (claude_proto.h kind 9), written after it subscribed to the answer
 * characteristic: "mac" (the daemon, direct) on any connection except the translator app's, "relay" (the iPhone
 * app) only on the connection that holds the translator audio role. One holder per role. A restored (bonded) CCCD
 * without a hello is no role. A hello that cannot be granted yet is kept for that subscription and granted as soon
 * as it can: a relay hello written before its link got the translator audio role (a restored audio CCCD waits for
 * the app's first translator write), a Mac hello while the Mac's previous, stale link still holds the role. The active link is the Mac, otherwise the relay. Voice is live when the active link
 * subscribed to the voice characteristic and its MTU fits one audio frame.
 * All calls from the NimBLE host task (ble_link.c).
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_LINK_PEERS 3
#define CLAUDE_CONN_NONE  0xffff   /* BLE_HS_CONN_HANDLE_NONE */

typedef enum {
    CLAUDE_ROLE_NONE = 0,
    CLAUDE_ROLE_MAC = 1,
    CLAUDE_ROLE_RELAY = 2,
} claude_role_t;

typedef struct {
    uint16_t conn;        /* CLAUDE_CONN_NONE: free slot */
    bool answer;          /* answer CCCD on (written or restored) */
    bool voice;           /* voice CCCD on */
    claude_role_t role;   /* granted from the hello; cleared with the answer CCCD */
    claude_role_t want;   /* the hello said (granted or waiting); cleared with the answer CCCD */
    uint16_t mtu;
} claude_peer_t;

typedef struct {
    claude_peer_t peer[CLAUDE_LINK_PEERS];
    uint16_t phone;       /* the connection holding the translator audio role */
} claude_links_t;

typedef struct {
    uint16_t active;      /* CLAUDE_CONN_NONE without a Claude link */
    bool relayed;         /* the active link is the iPhone relay */
    bool voice;
    uint16_t mtu;         /* of the active link, 0 without one */
} claude_link_state_t;

typedef enum {
    CLAUDE_LINK_EV_DOWN,       /* app_on_claude_link(false) (also ends voice) */
    CLAUDE_LINK_EV_UP,         /* app_on_claude_link(true) */
    CLAUDE_LINK_EV_VOICE_OFF,  /* app_on_claude_voice_link(false) */
    CLAUDE_LINK_EV_VOICE_ON,   /* app_on_claude_voice_link(true) */
} claude_link_ev_t;

void claude_links_init(claude_links_t *l);
/* Slot index of conn, -1 when unknown */
int claude_links_slot(const claude_links_t *l, uint16_t conn);
/* Answer / voice CCCD on or off. false: no free slot for a new connection (turning off never fails) */
bool claude_links_answer(claude_links_t *l, uint16_t conn, bool on);
bool claude_links_voice(claude_links_t *l, uint16_t conn, bool on);
void claude_links_mtu(claude_links_t *l, uint16_t conn, uint16_t mtu);
/* The translator audio role moved (CLAUDE_CONN_NONE: nobody); a relay elsewhere loses its role (it comes back with
 * the audio role on its link), a Mac role on conn is dropped for good, a waiting relay hello on conn is granted */
void claude_links_phone(claude_links_t *l, uint16_t conn);
void claude_links_disconnected(claude_links_t *l, uint16_t conn);
/* The hello of conn. true: conn holds the role now. false: not granted (not subscribed, a different role than the
 * one it said before, or not allowed yet: wrong connection for the role or role held elsewhere, kept until it is) */
bool claude_links_hello(claude_links_t *l, uint16_t conn, claude_role_t role);
/* Request writes are taken (into that link's reassembly buffer) only from answer-subscribed connections */
bool claude_links_may_write(const claude_links_t *l, uint16_t conn);
claude_link_state_t claude_links_state(const claude_links_t *l, uint16_t voice_min_mtu);
/* What the app must be told, in order, when the state goes from `was` to `now`. Returns the count (<= 3). */
size_t claude_link_events(claude_link_state_t was, claude_link_state_t now, claude_link_ev_t out[3]);
