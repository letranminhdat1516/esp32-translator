// firmware/test/test_sessions.c — build: cc -Wall -Werror -I../main -o /tmp/test_sessions test_sessions.c ../main/sessions.c ../main/claude_proto.c && /tmp/test_sessions
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "sessions.h"

static claude_session_t row(uint32_t handle, char state, int64_t updated, uint8_t flags, const char *project)
{
    claude_session_t r;
    memset(&r, 0, sizeof r);
    r.handle = handle;
    r.state = state;
    r.since = updated;
    r.updated = updated;
    r.flags = flags;
    snprintf(r.project, sizeof r.project, "%s", project);
    return r;
}

static void upsert_replaces_the_same_handle(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'w', 10, 0, "alpha");
    sessions_upsert(&s, &a);
    a.state = 'i';
    sessions_upsert(&s, &a);
    assert(s.n == 1 && s.rows[0].state == 'i');
}

static void order_is_needs_you_then_recent_then_handle(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t rs[] = { row(1, 'i', 10, 0, "a"), row(2, 'w', 30, 0, "b"), row(3, 'n', 5, 0, "c"),
                              row(4, 'e', 30, 0, "d") };
    for (int i = 0; i < 4; i++) {
        sessions_upsert(&s, &rs[i]);
    }
    const claude_session_t *out[SESSIONS_SHOWN];
    assert(sessions_sorted(&s, out, SESSIONS_SHOWN) == 4);
    assert(out[0]->handle == 3 && out[1]->handle == 4 && out[2]->handle == 2 && out[3]->handle == 1);
}

static void shows_at_most_six(void)
{
    sessions_t s;
    sessions_clear(&s);
    for (uint32_t h = 1; h <= 8; h++) {
        claude_session_t r = row(h, 'i', h, 0, "p");
        sessions_upsert(&s, &r);
    }
    const claude_session_t *out[SESSIONS_SHOWN];
    assert(s.n == 8 && sessions_sorted(&s, out, SESSIONS_SHOWN) == 6);
    assert(out[0]->handle == 8 && out[5]->handle == 3);
}

static void a_full_table_drops_the_least_relevant_row(void)
{
    sessions_t s;
    sessions_clear(&s);
    for (uint32_t h = 1; h <= SESSIONS_MAX; h++) {
        claude_session_t r = row(h, 'i', 10 + h, 0, "p");
        sessions_upsert(&s, &r);
    }
    claude_session_t extra = row(99, 'w', 100, 0, "new");
    sessions_upsert(&s, &extra);
    assert(s.n == SESSIONS_MAX);
    bool has_1 = false, has_99 = false;
    for (int i = 0; i < s.n; i++) {
        has_1 |= s.rows[i].handle == 1;
        has_99 |= s.rows[i].handle == 99;
    }
    assert(!has_1 && has_99);
}

static void remove_and_clear(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'i', 1, 0, "a"), b = row(2, 'i', 2, 0, "b");
    sessions_upsert(&s, &a);
    sessions_upsert(&s, &b);
    sessions_remove(&s, 1);
    sessions_remove(&s, 42);   /* unknown: nothing */
    assert(s.n == 1 && s.rows[0].handle == 2);
    sessions_clear(&s);
    assert(s.n == 0 && sessions_focused(&s) == NULL && sessions_badge(&s) == 0);
}

static void focus_is_exclusive_and_clears_unseen(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, 'i', 1, CLAUDE_SESSION_FOCUSED, "a"), b = row(2, 'i', 2, CLAUDE_SESSION_UNSEEN, "b");
    sessions_upsert(&s, &a);
    sessions_upsert(&s, &b);
    assert(sessions_focused(&s)->handle == 1 && sessions_badge(&s) == 1);
    sessions_set_focus(&s, 2);
    assert(sessions_focused(&s)->handle == 2 && sessions_badge(&s) == 0);
    claude_session_t a2 = row(1, 'i', 3, CLAUDE_SESSION_FOCUSED, "a");   /* the Mac moves focus back */
    sessions_upsert(&s, &a2);
    assert(sessions_focused(&s)->handle == 1);
    int focused = 0;
    for (int i = 0; i < s.n; i++) {
        focused += (s.rows[i].flags & CLAUDE_SESSION_FOCUSED) != 0;
    }
    assert(focused == 1);
}

static void badge_counts_unseen_rows_that_are_not_focused(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t rs[] = { row(1, 'i', 1, CLAUDE_SESSION_UNSEEN, "a"), row(2, 'i', 2, CLAUDE_SESSION_UNSEEN, "b"),
                              row(3, 'i', 3, CLAUDE_SESSION_UNSEEN | CLAUDE_SESSION_FOCUSED, "c"), row(4, 'w', 4, 0, "d") };
    for (int i = 0; i < 4; i++) {
        sessions_upsert(&s, &rs[i]);
    }
    assert(sessions_badge(&s) == 2);
}

static void elapsed_and_labels(void)
{
    char b[16];
    const struct { int64_t s; const char *want; } cases[] = {
        { -5, "<1m" }, { 0, "<1m" }, { 59, "<1m" }, { 60, "1m" }, { 3599, "59m" },
        { 3600, "1h 00m" }, { 7380, "2h 03m" }, { 100 * 3600 + 59, "100h 00m" },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        sessions_format_elapsed(cases[i].s, b, sizeof b);
        assert(strcmp(b, cases[i].want) == 0);
    }
    assert(strcmp(sessions_state_label('n'), "Needs you") == 0 && strcmp(sessions_state_label('w'), "Working") == 0);
    assert(strcmp(sessions_state_label('i'), "Idle") == 0 && strcmp(sessions_state_label('e'), "Ended") == 0);
    assert(strcmp(sessions_state_label('?'), "") == 0);
    assert(strcmp(sessions_state_short('n'), "needs you") == 0 && strcmp(sessions_state_short('e'), "ended") == 0);
    uint32_t c[4] = { sessions_state_color('n'), sessions_state_color('w'), sessions_state_color('i'), sessions_state_color('e') };
    assert(c[0] == 0xe5484d && c[1] == 0xf5c400 && c[2] == 0x30a46c && c[3] == 0x6f6f6f);
}

int main(void)
{
    upsert_replaces_the_same_handle();
    order_is_needs_you_then_recent_then_handle();
    shows_at_most_six();
    a_full_table_drops_the_least_relevant_row();
    remove_and_clear();
    focus_is_exclusive_and_clears_unseen();
    badge_counts_unseen_rows_that_are_not_focused();
    elapsed_and_labels();
    puts("sessions: all tests passed");
    return 0;
}
