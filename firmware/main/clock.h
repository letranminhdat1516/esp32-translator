/*
 * Wall clock for the lock face. The board has no clock source of its own: the iPhone (translator text
 * characteristic, kind 2) and the Mac (Claude message kind 3) send "<unix seconds> <UTC offset minutes>"
 * in ASCII on connect, e.g. "1759555200 420" or "1759555200 -330".
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int64_t unix_s;
    int offset_min;
} clock_sync_t;

/* Pure (host-tested): strict parse; rejects garbage, times before 2023-11-14 or after 2099, offsets beyond -12h..+14h */
bool clock_parse(const char *text, clock_sync_t *out);
/* Pure (host-tested): "HH:MM" local time; out must hold 6 bytes */
void clock_format_hhmm(int64_t unix_s, int offset_min, char out[6]);

/* Device (clock_rtc.c): sets the system time; safe from any task. Returns false (and changes nothing) on bad text. */
bool clock_sync_text(const char *text);
/* Device: "HH:MM", or "--:--" until a time has been received. Returns whether the time is known. */
bool clock_now_hhmm(char out[6]);
