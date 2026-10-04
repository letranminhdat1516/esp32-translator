/*
 * Board shell state machine (pure C, host-tested in firmware/test/test_modes.c).
 * Owns which mode is in use, the lock, the lock face timer and Claude "urgent" takeovers.
 * No ESP-IDF or LVGL here: shell.c feeds it events and applies the result.
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef enum { BOARD_TRANSLATOR = 0, BOARD_CLAUDE, BOARD_PICKER } board_mode_t;
typedef enum { SCREEN_TRANSLATOR = 0, SCREEN_CLAUDE, SCREEN_PICKER, SCREEN_LOCK } board_screen_t;

typedef enum {
    MODES_EV_PWR_1 = 0,
    MODES_EV_PWR_2,
    MODES_EV_PWR_3,
    MODES_EV_BOOT_1,
    MODES_EV_TAP_1,        /* single tap on the lock screen */
    MODES_EV_TAP_2,        /* double tap on the lock screen */
    MODES_EV_URGENT,       /* a Claude request needs the user: show it, wake the panel */
    MODES_EV_URGENT_DONE,  /* that request was answered, cancelled or dropped */
} modes_event_t;

/* Panel power policy: AUTO = the usual idle timer / manual screen-off decide */
typedef enum { MODES_PANEL_AUTO = 0, MODES_PANEL_ON, MODES_PANEL_OFF } modes_panel_t;

#define MODES_FACE_US (5LL * 1000 * 1000)   /* lock face stays up this long after a tap */

typedef struct {
    board_mode_t mode;       /* mode in use; shown when unlocked, restored on unlock */
    bool locked;
    bool urgent;             /* a Claude request is shown over the mode (or over the lock) */
    bool pending;            /* a Claude request awaits an answer (shown or left behind); unlocking shows it again */
    int64_t face_until_us;   /* lock face visible until this time; 0 = hidden */
} modes_t;

void modes_init(modes_t *m);
/* Applies one input. Returns true when the panel must wake now (clear manual screen-off, mark activity). */
bool modes_handle(modes_t *m, modes_event_t ev, int64_t now_us);
board_screen_t modes_screen(const modes_t *m);
modes_panel_t modes_panel(const modes_t *m, int64_t now_us);
bool modes_face_visible(const modes_t *m, int64_t now_us);

/* PWR button press counting, fed from the PMU interrupt poll (pmu.c, every 100 ms). */
#define MODES_CLICK_WINDOW_MS 450    /* a series ends once this long passes after the last release (~0.5 s at 100 ms polls) */
#define MODES_HOLD_MS         3000
#define MODES_CLICKS_HOLD     (-1)

typedef struct {
    bool down;
    bool hold_fired;
    uint32_t down_at_ms;
    uint32_t last_release_ms;
    int pending;
} modes_clicks_t;

/* pressed / released: the PMU key events seen in this poll (both may be set). Returns 0 (nothing yet),
 * 1..3 (a finished series; 4+ presses count as 3) or MODES_CLICKS_HOLD (held MODES_HOLD_MS, fired once). */
int modes_clicks_step(modes_clicks_t *c, bool pressed, bool released, uint32_t now_ms);
