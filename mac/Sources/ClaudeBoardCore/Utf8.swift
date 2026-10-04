import Foundation

/// Byte budgets for the board: its message text is at most 400 bytes of UTF-8 (firmware CLAUDE_TEXT_MAX).
public enum Utf8 {
    /// `s` if it fits; else the longest prefix of whole Characters plus "…" (3 bytes) within `maxBytes`;
    /// "" when not even the ellipsis fits.
    public static func fit(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes >= 3 else { return "" }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes - 3 { break }
            out.append(ch)
            used += n
        }
        return out + "…"
    }

    /// `s` if it fits; else "…" plus the longest suffix of whole Characters within `maxBytes` (live transcripts:
    /// the newest words matter); "" when not even the ellipsis fits.
    public static func fitTail(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes >= 3 else { return "" }
        var kept: [Character] = []
        var used = 0
        for ch in s.reversed() {
            let n = ch.utf8.count
            if used + n > maxBytes - 3 { break }
            kept.append(ch)
            used += n
        }
        return "…" + String(kept.reversed())
    }

    /// Fits every item into a share of `totalBytes`: items shorter than an even share keep their full
    /// length, the others split what is left evenly.
    public static func share(_ items: [String], totalBytes: Int) -> [String] {
        var budget = [Int](repeating: 0, count: items.count)
        var left = max(0, totalBytes)
        var open = items.indices.sorted { items[$0].utf8.count < items[$1].utf8.count }
        while let i = open.first {
            let each = left / open.count
            let need = items[i].utf8.count
            if need <= each {
                budget[i] = need
                left -= need
                open.removeFirst()
            } else {
                for j in open { budget[j] = each }
                open.removeAll()
            }
        }
        return items.indices.map { fit(items[$0], maxBytes: budget[$0]) }
    }

    /// One line: control characters (newlines, tabs, …) and line/paragraph separators become spaces, since
    /// "\n" separates fields on the wire. Format characters such as ZWJ are kept.
    public static func oneLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let control = u.properties.generalCategory == .control || u == "\u{2028}" || u == "\u{2029}"
            out.append(control ? " " : u)
        }
        return String(out)
    }
}
