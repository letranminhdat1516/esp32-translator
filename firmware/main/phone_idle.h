/*
 * iPhone app liveness (pure C, host-tested in firmware/test/test_phone_idle.c).
 * A bonded iPhone keeps the BLE link up for ANCS after the translator app is gone, and iOS may never write the
 * audio CCCD off: the board would stream audio into a dead link for hours. The app writes something (text, mic
 * state, or the keepalive byte every 20 s) while it runs; after PHONE_IDLE_TIMEOUT_US without a write the board
 * leaves the iPhone audio role (ble_link.c).
 */
#pragma once
#include <stdint.h>

#define PHONE_IDLE_TIMEOUT_US   (60LL * 1000 * 1000)
#define PHONE_IDLE_TIMEOUT_MS   ((uint32_t)(PHONE_IDLE_TIMEOUT_US / 1000))
/* Never re-check sooner than this: a timer tick may round a few ms down to "now" */
#define PHONE_IDLE_MIN_CHECK_MS 1000u

/* Control characteristic byte the app writes as a keepalive (0..2 are the mic states, rec_lang_t) */
#define PHONE_CTRL_KEEPALIVE    0xFF

/* Called when the idle check fires. 0: the app has been silent for the whole timeout, leave the role now.
 * Otherwise: ms until the next check (when the timeout would run out, at least PHONE_IDLE_MIN_CHECK_MS). */
static inline uint32_t phone_idle_check_ms(int64_t last_write_us, int64_t now_us)
{
    int64_t silent = now_us - last_write_us;
    if (silent < 0) {
        silent = 0;   /* a write stamped after "now" was read: the app is alive */
    }
    if (silent >= PHONE_IDLE_TIMEOUT_US) {
        return 0;
    }
    int64_t left_ms = (PHONE_IDLE_TIMEOUT_US - silent + 999) / 1000;
    return left_ms < PHONE_IDLE_MIN_CHECK_MS ? PHONE_IDLE_MIN_CHECK_MS : (uint32_t)left_ms;
}
