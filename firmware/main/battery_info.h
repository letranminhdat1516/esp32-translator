#ifndef BATTERY_INFO_H
#define BATTERY_INFO_H

/* Battery characteristic (A7C00006-...): [percent u8, 0xFF unknown][flags u8], read + notify, same protection as
 * control ...0004 (an LE Secure Connections MITM bond). The board notifies when the value changes (checked every
 * 30 s by pmu.c). Must match BoardBattery in ios/Sources/Core/BoardLink.swift. Pure C, host-tested in
 * firmware/test/test_battery_info.c. */

#include <stdbool.h>
#include <stdint.h>

#define BATTERY_PERCENT_UNKNOWN 0xFFu

#define BATTERY_PRESENT  0x01u
#define BATTERY_CHARGING 0x02u
#define BATTERY_USB      0x04u

static inline void battery_info_encode(bool present, int percent, bool charging, bool usb, uint8_t out[2])
{
    out[0] = present && percent >= 0 && percent <= 100 ? (uint8_t)percent : BATTERY_PERCENT_UNKNOWN;
    out[1] = (uint8_t)((present ? BATTERY_PRESENT : 0) | (charging ? BATTERY_CHARGING : 0) | (usb ? BATTERY_USB : 0));
}

#endif /* BATTERY_INFO_H */
