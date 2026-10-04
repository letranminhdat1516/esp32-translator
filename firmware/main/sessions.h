/*
 * Claude sessions as the board holds them (pure C, host-tested in firmware/test/test_sessions.c).
 * The Mac sends at most 6 rows (kind 4 upserts, 5 removes, 6 clears); the table keeps up to 8 as a safety
 * margin. Order matches the Mac (SessionRow.boardOrder): "needs you" first, then most recently updated,
 * then the higher handle. On the board the table is guarded by the display lock (picker_ui.c).
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

#define SESSIONS_MAX   8
#define SESSIONS_SHOWN 6

typedef struct {
    claude_session_t rows[SESSIONS_MAX];
    int n;
} sessions_t;

void sessions_clear(sessions_t *s);
/* Adds or replaces the row with this handle; a row carrying FOCUSED takes the flag from the others.
 * A full table drops its least relevant row (the incoming one if it sorts after every other row), never the
 * focused one. Rows with handle 0 are ignored. */
void sessions_upsert(sessions_t *s, const claude_session_t *row);
void sessions_remove(sessions_t *s, uint32_t handle);   /* handle 0: nothing */
/* true when a comes before b in the picker */
bool sessions_before(const claude_session_t *a, const claude_session_t *b);
/* Fills out with at most max rows in picker order; returns the count */
int sessions_sorted(const sessions_t *s, const claude_session_t **out, int max);
const claude_session_t *sessions_focused(const sessions_t *s);
/* Done events of non-focused sessions not seen yet */
int sessions_badge(const sessions_t *s);
/* Optimistic local focus after a picker tap (the Mac confirms with upserts) */
void sessions_set_focus(sessions_t *s, uint32_t handle);
/* "<1m", "12m", "2h 05m" (negative = clock skew: "<1m") */
void sessions_format_elapsed(int64_t seconds, char *out, size_t n);
const char *sessions_state_label(char state);   /* "Needs you", "Working", "Idle", "Ended" */
const char *sessions_state_short(char state);   /* "needs you", "working", "idle", "ended" */
uint32_t sessions_state_color(char state);      /* red, yellow, green, grey (0xRRGGBB) */
