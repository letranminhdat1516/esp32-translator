import Foundation

// Port of app/lib/core/board_glyphs.dart; contract: shared/fixtures/board_text.json (`parseRanges`, `glyphs`).

/// The exact code points of the board's partition fonts (CJK, Hangul, Thai).
///
/// Those fonts are subsets, so whole Unicode blocks are not drawable. The lists are generated from the font files by
/// `firmware/tools/gen_glyph_sets.py` into `shared/board_glyphs/<set>.txt`, one `XXXX-YYYY` or `XXXX` per line.
struct BoardGlyphSets: Hashable, Sendable {
    /// A line of a list that is neither blank, a `#` comment, `XXXX` nor `XXXX-YYYY` (lo ≤ hi).
    struct BadRange: Error, Equatable, CustomStringConvertible {
        let line: String
        var description: String { "bad glyph range: \(line)" }
    }

    private let cjk: [ClosedRange<Int>]
    private let hangul: [ClosedRange<Int>]
    private let thai: [ClosedRange<Int>]

    init(cjk: [ClosedRange<Int>] = [], hangul: [ClosedRange<Int>] = [], thai: [ClosedRange<Int>] = []) {
        self.cjk = cjk.sorted { $0.lowerBound < $1.lowerBound }
        self.hangul = hangul.sorted { $0.lowerBound < $1.lowerBound }
        self.thai = thai.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Reads the text of the three list files (see `parseRanges`).
    static func parse(cjk: String, hangul: String, thai: String) throws -> BoardGlyphSets {
        try BoardGlyphSets(cjk: parseRanges(cjk), hangul: parseRanges(hangul), thai: parseRanges(thai))
    }

    /// The lists the app ships (`board_glyphs/*.txt` in the bundle), loaded once. If they cannot be read this
    /// asserts (debug and tests) and is empty, so non-Latin characters take the `·` fallback rather than crash
    /// subtitle sending.
    static let shared: BoardGlyphSets = {
        do {
            func text(_ name: String) throws -> String {
                String(decoding: try SharedResources.data(.boardGlyphs, name, "txt"), as: UTF8.self)
            }
            return try parse(cjk: text("cjk"), hangul: text("hangul"), thai: text("thai"))
        } catch {
            SharedResources.reportMissing("board glyph lists (non-Latin text shows as ·)", error)
            assertionFailure("board glyph lists: \(error)")
            return BoardGlyphSets()
        }
    }()

    /// The ranges of the fonts `sets` selects (cjk, hangul and thai bits only).
    func ranges(for sets: FontSets) -> [ClosedRange<Int>] {
        (sets.contains(.cjk) ? cjk : []) + (sets.contains(.hangul) ? hangul : []) + (sets.contains(.thai) ? thai : [])
    }

    /// Parses `XXXX-YYYY` / `XXXX` lines (hex, no prefix). Blank lines and `#` comments are skipped; anything else
    /// throws `BadRange`.
    static func parseRanges(_ text: String) throws -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        // Foundation splits "\r\n" too (a Swift Character split would not: "\r\n" is one Character)
        for raw in text.components(separatedBy: "\n") {
            let line = raw.dartTrimmed
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "-", omittingEmptySubsequences: false)
            let lo = Int(parts[0], radix: 16)
            let hi = parts.count == 1 ? lo : (parts.count == 2 ? Int(parts[1], radix: 16) : nil)
            guard let lo, let hi, hi >= lo else { throw BadRange(line: line) }
            out.append(lo...hi)
        }
        return out
    }
}
