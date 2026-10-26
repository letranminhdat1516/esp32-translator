#!/usr/bin/env python3
"""Writes the exact code points of each partition font to app/assets/board_glyphs/<set>.txt.

Reads the committed LVGL bin fonts (firmware/fonts/<set>_<px>.bin, 'cmap' table), so it works offline and
lists what the board can really draw, not what was asked of lv_font_conv. The 22 px and 36 px fonts must
agree. Output: one 'XXXX-YYYY' or 'XXXX' (upper-case hex, no prefix) per line, ascending.

  gen_glyph_sets.py [fonts_dir] [out_dir]
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SETS = ("cjk", "hangul", "thai")


def code_points(path):
    d = open(path, "rb").read()
    off = 0
    while off < len(d):
        size, tag = struct.unpack_from("<I4s", d, off)
        if tag == b"cmap":
            break
        off += size
    else:
        raise SystemExit("%s: no cmap table" % path)
    (count,) = struct.unpack_from("<I", d, off + 8)
    out = set()
    for i in range(count):
        data_off, start, length, gid_start, entries, kind = struct.unpack_from("<IIHHHB", d, off + 12 + 16 * i)
        base = off + data_off
        if kind == 2:  # format0_tiny: contiguous range, ids consecutive
            out.update(range(start, start + length))
        elif kind == 3:  # sparse_tiny: u16 offsets
            out.update(start + o for o in struct.unpack_from("<%dH" % entries, d, base))
        elif kind == 1:  # sparse_full: u16 offsets, then u16 ids
            out.update(start + o for o in struct.unpack_from("<%dH" % entries, d, base))
        elif kind == 0:  # format0_full: u8 id offset per code point; 0 = absent, except the first (id = gid_start)
            ids = d[base:base + length]
            out.update(start + j for j, v in enumerate(ids) if v != 0 or j == 0)
        else:
            raise SystemExit("%s: unknown cmap kind %d" % (path, kind))
    return out


def ranges(cps):
    cps = sorted(cps)
    lo = prev = cps[0]
    for c in cps[1:]:
        if c != prev + 1:
            yield lo, prev
            lo = c
        prev = c
    yield lo, prev


def main():
    fonts = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "fonts")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "..", "app", "assets", "board_glyphs")
    os.makedirs(out, exist_ok=True)
    for name in SETS:
        a, b = (code_points(os.path.join(fonts, "%s_%d.bin" % (name, px))) for px in (22, 36))
        if a != b:
            raise SystemExit("%s: 22 px and 36 px fonts differ (%d vs %d glyphs)" % (name, len(a), len(b)))
        lines = ["%04X" % lo if lo == hi else "%04X-%04X" % (lo, hi) for lo, hi in ranges(a)]
        with open(os.path.join(out, name + ".txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        print("%s: %d code points, %d lines" % (name, len(a), len(lines)))


if __name__ == "__main__":
    main()
