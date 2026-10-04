#include "claude_link.h"

#define DEFAULT_MTU 23

static void clear(claude_peer_t *p)
{
    *p = (claude_peer_t){ .conn = CLAUDE_CONN_NONE, .mtu = DEFAULT_MTU };
}

void claude_links_init(claude_links_t *l)
{
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        clear(&l->peer[i]);
    }
    l->phone = CLAUDE_CONN_NONE;
}

int claude_links_slot(const claude_links_t *l, uint16_t conn)
{
    if (conn == CLAUDE_CONN_NONE) {
        return -1;
    }
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        if (l->peer[i].conn == conn) {
            return i;
        }
    }
    return -1;
}

static claude_peer_t *find_or_add(claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    if (i >= 0) {
        return &l->peer[i];
    }
    if (conn == CLAUDE_CONN_NONE) {
        return NULL;
    }
    for (i = 0; i < CLAUDE_LINK_PEERS; i++) {
        if (l->peer[i].conn == CLAUDE_CONN_NONE) {
            clear(&l->peer[i]);
            l->peer[i].conn = conn;
            return &l->peer[i];
        }
    }
    return NULL;
}

bool claude_links_answer(claude_links_t *l, uint16_t conn, bool on)
{
    int i = claude_links_slot(l, conn);
    claude_peer_t *p = on ? find_or_add(l, conn) : (i >= 0 ? &l->peer[i] : NULL);
    if (p == NULL) {
        return !on;
    }
    p->answer = on;
    if (!on) {
        p->role = CLAUDE_ROLE_NONE;
        p->want = CLAUDE_ROLE_NONE;
    }
    return true;
}

bool claude_links_voice(claude_links_t *l, uint16_t conn, bool on)
{
    int i = claude_links_slot(l, conn);
    claude_peer_t *p = on ? find_or_add(l, conn) : (i >= 0 ? &l->peer[i] : NULL);
    if (p == NULL) {
        return !on;
    }
    p->voice = on;
    return true;
}

void claude_links_mtu(claude_links_t *l, uint16_t conn, uint16_t mtu)
{
    claude_peer_t *p = find_or_add(l, conn);
    if (p != NULL) {
        p->mtu = mtu;
    }
}

static bool role_held_elsewhere(const claude_links_t *l, int i, claude_role_t role)
{
    for (int j = 0; j < CLAUDE_LINK_PEERS; j++) {
        if (j != i && l->peer[j].conn != CLAUDE_CONN_NONE && l->peer[j].role == role) {
            return true;
        }
    }
    return false;
}

/* Grants each waiting hello that is allowed now */
static void grant_waiting(claude_links_t *l)
{
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        claude_peer_t *p = &l->peer[i];
        if (p->conn == CLAUDE_CONN_NONE || !p->answer || p->want == CLAUDE_ROLE_NONE || p->role != CLAUDE_ROLE_NONE) {
            continue;
        }
        if (p->want == CLAUDE_ROLE_MAC && p->conn == l->phone) {
            continue;   /* a Mac never holds the translator audio role */
        }
        if (p->want == CLAUDE_ROLE_RELAY && p->conn != l->phone) {
            continue;   /* the relay is the translator app itself */
        }
        if (!role_held_elsewhere(l, i, p->want)) {
            p->role = p->want;
        }
    }
}

void claude_links_phone(claude_links_t *l, uint16_t conn)
{
    l->phone = conn;
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        claude_peer_t *p = &l->peer[i];
        if (p->role == CLAUDE_ROLE_RELAY && p->conn != conn) {
            p->role = CLAUDE_ROLE_NONE;   /* want stays: back with the audio role on this link */
        }
        if (p->want == CLAUDE_ROLE_MAC && conn != CLAUDE_CONN_NONE && p->conn == conn) {
            p->role = CLAUDE_ROLE_NONE;   /* the translator app's link is never the Mac */
            p->want = CLAUDE_ROLE_NONE;
        }
    }
    grant_waiting(l);
}

void claude_links_disconnected(claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    if (i >= 0) {
        clear(&l->peer[i]);
    }
    if (l->phone == conn) {
        l->phone = CLAUDE_CONN_NONE;
    }
    grant_waiting(l);   /* a waiting Mac hello on a newer link of the same Mac */
}

bool claude_links_hello(claude_links_t *l, uint16_t conn, claude_role_t role)
{
    int i = claude_links_slot(l, conn);
    if (i < 0 || !l->peer[i].answer || role == CLAUDE_ROLE_NONE) {
        return false;
    }
    claude_peer_t *p = &l->peer[i];
    if (p->want != CLAUDE_ROLE_NONE && p->want != role) {
        return false;   /* one role per subscription */
    }
    if (role == CLAUDE_ROLE_MAC && conn == l->phone) {
        return false;   /* the translator app's link is never the Mac: not kept either */
    }
    p->want = role;
    grant_waiting(l);
    return p->role == role;
}

bool claude_links_may_write(const claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    return i >= 0 && l->peer[i].answer;
}

claude_link_state_t claude_links_state(const claude_links_t *l, uint16_t voice_min_mtu)
{
    const claude_peer_t *mac = NULL, *relay = NULL;
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        const claude_peer_t *p = &l->peer[i];
        if (p->conn == CLAUDE_CONN_NONE || !p->answer) {
            continue;
        }
        if (p->role == CLAUDE_ROLE_MAC) {
            mac = p;
        } else if (p->role == CLAUDE_ROLE_RELAY) {
            relay = p;
        }
    }
    const claude_peer_t *a = mac != NULL ? mac : relay;
    claude_link_state_t s = { .active = CLAUDE_CONN_NONE };
    if (a != NULL) {
        s.active = a->conn;
        s.relayed = a == relay;
        s.voice = a->voice && a->mtu >= voice_min_mtu;
        s.mtu = a->mtu;
    }
    return s;
}

size_t claude_link_events(claude_link_state_t was, claude_link_state_t now, claude_link_ev_t out[3])
{
    size_t n = 0;
    if (was.active != now.active) {
        if (was.active != CLAUDE_CONN_NONE) {
            out[n++] = CLAUDE_LINK_EV_DOWN;
        }
        if (now.active != CLAUDE_CONN_NONE) {
            out[n++] = CLAUDE_LINK_EV_UP;
            if (now.voice) {
                out[n++] = CLAUDE_LINK_EV_VOICE_ON;
            }
        }
    } else if (was.voice != now.voice) {
        out[n++] = now.voice ? CLAUDE_LINK_EV_VOICE_ON : CLAUDE_LINK_EV_VOICE_OFF;
    }
    return n;
}
