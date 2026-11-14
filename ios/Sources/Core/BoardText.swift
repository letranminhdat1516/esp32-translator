import Foundation
import Synchronization

// Contract: shared/fixtures/board_text.json.

/// Makes text safe for the board: every character left is one the board's fonts can draw, given the glyph sets it
/// reports (`FontSets`).
///
/// - Characters in the drawable ranges pass through.
/// - Cyrillic and Greek are transliterated to Latin; with no CJK font Japanese kana becomes romaji.
/// - Latin letters the fonts lack are folded to ASCII (`Ł` → `L`, `ž` → `z`), fullwidth and other compatibility forms
///   to their plain equivalents, a few symbols are spelled (`€` → `EUR`).
/// - Letters of a script with no table and no font (Han, Hangul, Thai, Arabic, …) give `·`, once per run, so a word
///   with nothing drawable becomes a single `·`. Marks, emoji and other symbols are dropped.
/// - Whitespace and control characters collapse to single spaces.
/// - The result is never empty for non-blank input: when nothing is left it is `·`. Blank input stays blank (there is
///   nothing to show).
final class BoardText: Sendable {
    // The canonical ranges (progress.md ruling). latinVI is the firmware's `-r` list; latinExtA adds U+0100-U+017F,
    // which contains the four single Vietnamese letter pairs that latinVI lists on their own.
    private static let latinVI: [ClosedRange<Int>] = [
        0x20...0x7E, 0xA0...0xFF, 0x102...0x103, 0x110...0x111, 0x128...0x129, 0x168...0x169, 0x1A0...0x1A1,
        0x1AF...0x1B0, 0x1EA0...0x1EF9, 0x2013...0x2014, 0x2018...0x201D, 0x2026...0x2026,
    ]
    private static let latinExtA: [ClosedRange<Int>] = [0x100...0x17F]
    private static let dot = "·"

    /// The exact code points of the CJK, Hangul and Thai fonts (subsets, not whole blocks). Nil means
    /// `BoardGlyphSets.shared`; it is only read for a board with one of those fonts.
    let glyphs: BoardGlyphSets?

    /// Merged ranges per font bits.
    private let cache = Mutex<[UInt32: [ClosedRange<Int>]]>([:])

    init(glyphs: BoardGlyphSets? = nil) {
        self.glyphs = glyphs
    }

    /// The code point ranges the board can draw with `sets`, sorted, ranges that overlap merged. Latin Basic and the
    /// Vietnamese letters are always included: a board that reports no Latin bit is treated as latinVI. The CJK,
    /// Hangul and Thai fonts are subsets: only their listed code points are included.
    func ranges(_ sets: FontSets) -> [ClosedRange<Int>] {
        if let cached = cache.withLock({ $0[sets.rawValue] }) { return cached }
        let extra: FontSets = [.cjk, .hangul, .thai]
        let source = sets.isDisjoint(with: extra) ? nil : (glyphs ?? BoardGlyphSets.shared)
        let all = (Self.latinVI + (sets.contains(.latinExtA) ? Self.latinExtA : []) + (source?.ranges(for: sets) ?? []))
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in all {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        cache.withLock { $0[sets.rawValue] = merged }
        return merged
    }

    /// True when the board can draw `codePoint` with `sets`.
    func isDrawable(_ codePoint: Int, _ sets: FontSets) -> Bool {
        Self.contains(ranges(sets), codePoint)
    }

    /// Binary search of sorted, merged `ranges`.
    private static func contains(_ r: [ClosedRange<Int>], _ codePoint: Int) -> Bool {
        var lo = 0, hi = r.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if codePoint < r[mid].lowerBound {
                hi = mid - 1
            } else if codePoint > r[mid].upperBound {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// The private helpers take the merged ranges of one `encode` call (`Drawable`), not the font sets, so the
    /// cache is read once per call instead of once per code point.
    private typealias Drawable = [ClosedRange<Int>]

    private func isDrawable(_ s: Unicode.Scalar, _ drawable: Drawable) -> Bool {
        Self.contains(drawable, Int(s.value))
    }

    /// Word separators: JavaScript/Dart `\s`, C0 and C1 controls.
    private static func isSeparator(_ s: Unicode.Scalar) -> Bool {
        s.isDartWhitespace || s.value <= 0x1F || (0x7F...0x9F).contains(s.value)
    }

    /// `text` as the board can show it.
    func encode(_ text: String, _ sets: FontSets) -> String {
        let source = text.nfc
        let drawable = ranges(sets)
        var words: [String] = []
        var word = String.UnicodeScalarView()
        func flush() {
            if !word.isEmpty {
                let encoded = self.word(Array(word), drawable)
                if !encoded.isEmpty { words.append(encoded) }
                word = String.UnicodeScalarView()
            }
        }
        for s in source.unicodeScalars {
            if Self.isSeparator(s) { flush() } else { word.append(s) }
        }
        flush()
        // Collapse runs of spaces (spellings such as "、" → ", " can add one), then trim.
        var out = ""
        for c in words.joined(separator: " ").unicodeScalars where !(c == " " && out.unicodeScalars.last == " ") {
            out.unicodeScalars.append(c)
        }
        out = out.dartTrimmed
        if !out.isEmpty { return out }
        return source.dartTrimmed.isEmpty ? "" : Self.dot
    }

    private func word(_ input: [Unicode.Scalar], _ sets: Drawable) -> String {
        let scalars = compatibilityFolded(input, sets)

        // A word of capitals keeps its transliteration in capitals ("ЖУК" → "ZHUK", not "ZhUK").
        let letters = scalars.filter(Translit.hasLetterTable)
        let allCaps = letters.count >= 2 && letters.allSatisfy { String($0).lowercased() != String($0) }

        var parts: [String] = []
        func dot() {
            if parts.last != Self.dot { parts.append(Self.dot) }
        }

        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            i += 1
            if isDrawable(s, sets) {
                parts.append(String(s))
                continue
            }
            if let letter = Translit.letter(s, allCaps: allCaps, afterOmicron: i >= 2 && Translit.isOmicron(scalars[i - 2])) {
                parts.append(letter)
                continue
            }
            if Translit.isKana(s) {
                if let kana = Translit.readKana(scalars, i - 1) {
                    parts.append(kana.romaji)
                    i += kana.count - 1
                } else {
                    dot()
                }
                continue
            }
            if let spelled = Translit.punctuation[s] ?? Translit.latinSpecial(s) ?? Translit.asciiDigit(s)
                ?? foldMarks(s, sets) {
                parts.append(spelled)
                continue
            }
            if s.isMarkCategory || s.isOtherCategory { continue }
            if s.isLetterCategory || s.isNumberCategory { dot() }
            // Anything else (symbols, emoji, other punctuation) is dropped.
        }
        return parts.joined()
    }

    /// Replaces characters the board cannot draw and no table covers by their compatibility form (fullwidth letters,
    /// ligatures, circled digits, halfwidth katakana), when that gives something different.
    private func compatibilityFolded(_ scalars: [Unicode.Scalar], _ sets: Drawable) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for s in scalars {
            let handled = isDrawable(s, sets) || Translit.hasLetterTable(s) || Translit.isKana(s)
                || Translit.punctuation[s] != nil || Translit.latinSpecial(s) != nil || Translit.asciiDigit(s) != nil
                || foldMarks(s, sets) != nil
            if handled {
                out.append(s)
            } else {
                out.append(contentsOf: String(s).precomposedStringWithCompatibilityMapping.unicodeScalars)
            }
        }
        return out
    }

    /// A Latin letter with its marks removed, when the result can be drawn (`ž` → `z`, `ǎ` → `a`); nil otherwise.
    private func foldMarks(_ s: Unicode.Scalar, _ sets: Drawable) -> String? {
        let base = String(s).decomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.isMarkCategory }
        if base.isEmpty || (base.count == 1 && base.first == s) { return nil }
        guard base.allSatisfy({ isDrawable($0, sets) }) else { return nil }
        return String(base)
    }
}
