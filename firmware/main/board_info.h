#ifndef BOARD_INFO_H
#define BOARD_INFO_H

/* Board info characteristic (A7C00005-...): [version u8][fontSets u32 LE], 5 bytes, readable without pairing.
 * The FONTSET_* bits must match FontSets in ios/Sources/Core/Model.swift.
 *
 * Version: 1 = font sets (and the language label, kind 3); 2 = same layout, and the board enforces pairing by code
 * (pairing.h: text, control and the audio / control CCCDs need an LE Secure Connections MITM bond). The iPhone app
 * pins a board as "secure" only when it reports >= 2 and its protected read of control ...0004 succeeded, and it
 * refuses a board pinned that way that later reports < 2. Never report 2 from firmware that does not enforce
 * pairing (README "BLE pairing"). */

#define BOARD_INFO_VERSION 2

#define FONTSET_LATIN_VI    0x01u
#define FONTSET_LATIN_EXT_A 0x02u
#define FONTSET_CJK         0x04u
#define FONTSET_HANGUL      0x08u
#define FONTSET_THAI        0x10u

#endif /* BOARD_INFO_H */
