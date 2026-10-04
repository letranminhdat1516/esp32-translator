import Foundation

/// The rules for text that voice puts into a Claude Code session. The board shows the result of `forTyping`
/// before the user confirms, so what they read is exactly what is typed (or answered).
public enum VoiceText {
    /// Firmware CLAUDE_VOICE_TEXT_MAX
    public static let maxBytes = 300

    /// Control characters and line/paragraph separators become spaces, bidi controls and every other format
    /// character (Cf: zero-width spaces/joiners, BOM, soft hyphen…) are dropped, typographic
    /// quotes become ASCII (the board fonts have no curly quotes), whitespace runs collapse, the text is trimmed,
    /// leading "!", "/" and "#" are removed (Claude Code's bash, slash-command and memory modes), and the result
    /// is cut to `maxBytes` at a Character boundary without an ellipsis.
    public static func forTyping(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.value {
            case 0x2018, 0x2019: scalars.append("'")
            case 0x201C, 0x201D: scalars.append("\"")
            default:
                let category = u.properties.generalCategory
                if category == .format { continue }
                let control = category == .control || u.value == 0x2028 || u.value == 0x2029
                scalars.append(control ? " " : u)
            }
        }
        var s = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = s.first, c == "!" || c == "/" || c == "#" || c == " " { s.removeFirst() }
        return cap(s)
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
