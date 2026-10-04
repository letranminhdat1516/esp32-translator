import Foundation

/// The rules for text that voice puts into a Claude Code session. The board shows the result of `forTyping`
/// before the user confirms, so what they read is exactly what is typed (or answered).
public enum VoiceText {
    /// Firmware CLAUDE_VOICE_TEXT_MAX
    public static let maxBytes = 300

    /// The text is NFC-normalised first. Control characters and line/paragraph separators become spaces, bidi
    /// controls and every other format character (Cf: zero-width spaces/joiners, BOM, soft hyphen…) are dropped,
    /// typographic quotes become ASCII and hyphens/minus "-". Anything else the board font (font_vi_22/36) cannot
    /// draw becomes its base letter when that one can be drawn ("ō" → "o"), a space when it is whitespace, and is
    /// dropped otherwise (emoji, CJK…), so the board shows exactly what is typed. Whitespace runs collapse, the
    /// text is trimmed, leading "!", "/" and "#" are removed (Claude Code's bash, slash-command and memory modes),
    /// the result is cut to `maxBytes` at a Character boundary without an ellipsis, and trailing backslashes are
    /// removed (backslash + Enter inserts a newline in Claude Code instead of submitting).
    public static func forTyping(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.value {
            case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: scalars.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: scalars.append("\"")
            case 0x2010, 0x2011, 0x2012, 0x2212: scalars.append("-")
            default:
                let category = u.properties.generalCategory
                if category == .format { continue }
                if category == .control || u.value == 0x2028 || u.value == 0x2029 {
                    scalars.append(" ")
                } else if drawable(u) {
                    scalars.append(u)
                } else if let base = String(u).decomposedStringWithCanonicalMapping.unicodeScalars.first,
                          drawable(base) {
                    scalars.append(base)
                } else if u.properties.isWhitespace {
                    scalars.append(" ")
                }
            }
        }
        var s = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = s.first, c == "!" || c == "/" || c == "#" || c == " " { s.removeFirst() }
        s = cap(s)
        while let c = s.last, c == "\\" || c == " " { s.removeLast() }
        return s
    }

    /// The code points of the board fonts (firmware/main/font_vi_22.c and font_vi_36.c, "Opts: -r …")
    static func drawable(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x20...0x7E, 0xA0...0xFF, 0x102, 0x103, 0x110, 0x111, 0x128, 0x129, 0x168, 0x169, 0x1A0, 0x1A1,
             0x1AF, 0x1B0, 0x1EA0...0x1EF9, 0x2013, 0x2014, 0x2026:
            return true
        default:
            return false
        }
    }

    static func cap(_ s: String) -> String {
        if s.utf8.count <= maxBytes { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
