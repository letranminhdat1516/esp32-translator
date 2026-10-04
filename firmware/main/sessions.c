#include "sessions.h"

#include <stdio.h>
#include <string.h>

void sessions_clear(sessions_t *s)
{
    s->n = 0;
}

static int find(const sessions_t *s, uint32_t handle)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].handle == handle) {
            return i;
        }
    }
    return -1;
}

bool sessions_before(const claude_session_t *a, const claude_session_t *b)
{
    bool an = a->state == CLAUDE_STATE_NEEDS_YOU, bn = b->state == CLAUDE_STATE_NEEDS_YOU;
    if (an != bn) {
        return an;
    }
    if (a->updated != b->updated) {
        return a->updated > b->updated;
    }
    return a->handle > b->handle;
}

/* Full table: the row that sorts last among those that may go (never the focused one); -1 if none */
static int least_relevant(const sessions_t *s)
{
    int last = -1;
    for (int j = 0; j < s->n; j++) {
        if (s->rows[j].flags & CLAUDE_SESSION_FOCUSED) {
            continue;
        }
        if (last < 0 || sessions_before(&s->rows[last], &s->rows[j])) {
            last = j;
        }
    }
    return last;
}

void sessions_upsert(sessions_t *s, const claude_session_t *row)
{
    if (row->handle == 0) {
        return;   /* handles are never 0 */
    }
    int i = find(s, row->handle);
    if (i < 0) {
        if (s->n < SESSIONS_MAX) {
            i = s->n++;
        } else {
            i = least_relevant(s);
            /* A new row that sorts after every row that could go is the one dropped (unless it is focused) */
            if (i < 0 || (!(row->flags & CLAUDE_SESSION_FOCUSED) && sessions_before(&s->rows[i], row))) {
                return;
            }
        }
    }
    s->rows[i] = *row;
    if (row->flags & CLAUDE_SESSION_FOCUSED) {
        for (int j = 0; j < s->n; j++) {
            if (j != i) {
                s->rows[j].flags &= (uint8_t)~CLAUDE_SESSION_FOCUSED;
            }
        }
    }
}

void sessions_remove(sessions_t *s, uint32_t handle)
{
    if (handle == 0) {
        return;
    }
    int i = find(s, handle);
    if (i >= 0) {
        s->rows[i] = s->rows[--s->n];
    }
}

int sessions_sorted(const sessions_t *s, const claude_session_t **out, int max)
{
    const claude_session_t *all[SESSIONS_MAX];
    for (int i = 0; i < s->n; i++) {
        const claude_session_t *r = &s->rows[i];
        int j = i;
        while (j > 0 && sessions_before(r, all[j - 1])) {
            all[j] = all[j - 1];
            j--;
        }
        all[j] = r;
    }
    int k = s->n < max ? s->n : max;
    for (int i = 0; i < k; i++) {
        out[i] = all[i];
    }
    return k;
}

const claude_session_t *sessions_focused(const sessions_t *s)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].flags & CLAUDE_SESSION_FOCUSED) {
            return &s->rows[i];
        }
    }
    return NULL;
}

int sessions_badge(const sessions_t *s)
{
    int n = 0;
    for (int i = 0; i < s->n; i++) {
        uint8_t f = s->rows[i].flags;
        n += (f & CLAUDE_SESSION_UNSEEN) && !(f & CLAUDE_SESSION_FOCUSED);
    }
    return n;
}

void sessions_set_focus(sessions_t *s, uint32_t handle)
{
    for (int i = 0; i < s->n; i++) {
        if (s->rows[i].handle == handle) {
            s->rows[i].flags = CLAUDE_SESSION_FOCUSED;   /* focused: no longer unseen */
        } else {
            s->rows[i].flags &= (uint8_t)~CLAUDE_SESSION_FOCUSED;
        }
    }
}

void sessions_format_elapsed(int64_t seconds, char *out, size_t n)
{
    if (seconds < 60) {
        snprintf(out, n, "<1m");
    } else if (seconds < 3600) {
        snprintf(out, n, "%dm", (int)(seconds / 60));
    } else {
        snprintf(out, n, "%dh %02dm", (int)(seconds / 3600), (int)(seconds % 3600 / 60));
    }
}

const char *sessions_state_label(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return "Needs you";
    case CLAUDE_STATE_WORKING:   return "Working";
    case CLAUDE_STATE_IDLE:      return "Idle";
    case CLAUDE_STATE_ENDED:     return "Ended";
    default:                     return "";
    }
}

const char *sessions_state_short(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return "needs you";
    case CLAUDE_STATE_WORKING:   return "working";
    case CLAUDE_STATE_IDLE:      return "idle";
    case CLAUDE_STATE_ENDED:     return "ended";
    default:                     return "";
    }
}

uint32_t sessions_state_color(char state)
{
    switch (state) {
    case CLAUDE_STATE_NEEDS_YOU: return 0xe5484d;   /* red */
    case CLAUDE_STATE_WORKING:   return 0xf5c400;   /* yellow */
    case CLAUDE_STATE_IDLE:      return 0x30a46c;   /* green */
    default:                     return 0x6f6f6f;   /* grey: ended */
    }
}
