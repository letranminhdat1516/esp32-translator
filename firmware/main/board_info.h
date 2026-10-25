#ifndef BOARD_INFO_H
#define BOARD_INFO_H

/* Board info characteristic (A7C00005-...): [version u8][fontSets u32 LE].
 * The FONTSET_* bits must match FontSets in app/lib/core/model.dart. */

#define BOARD_INFO_VERSION 1

#define FONTSET_LATIN_VI    0x01u
#define FONTSET_LATIN_EXT_A 0x02u
#define FONTSET_CJK         0x04u
#define FONTSET_HANGUL      0x08u
#define FONTSET_THAI        0x10u

#endif /* BOARD_INFO_H */
