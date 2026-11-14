import Foundation

// Small Unicode helpers shared by the text modules (RuleEngine, TermProtector, BoardText, Glossary), so the Swift core
// answers "is this a letter / whitespace / …" the same way the shared fixtures expect (Dart / JavaScript semantics).

extension Unicode.Scalar {
    /// `\p{L}`.
    var isLetterCategory: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// `\p{N}`.
    var isNumberCategory: Bool {
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// `\p{M}`.
    var isMarkCategory: Bool {
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// `\p{C}` (control, format, surrogate, private use, unassigned).
    var isOtherCategory: Bool {
        switch properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }

    /// Whitespace as Dart's `String.trim` defines it. JavaScript's `\s` / `trim` is the same set minus U+0085 (NEL,
    /// Dart-only); where this splits words (BoardText) NEL is a C1 control and a separator anyway.
    var isDartWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default: false
        }
    }
}

extension String {
    /// Unicode NFC.
    var nfc: String { precomposedStringWithCanonicalMapping }

    /// Dart `trim()`: drops leading and trailing `isDartWhitespace` scalars.
    var dartTrimmed: String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.isDartWhitespace }) else { return "" }
        let last = scalars.lastIndex(where: { !$0.isDartWhitespace })!
        return String(scalars[first...last])
    }

    /// The whole string as an `NSRange` (UTF-16), for `NSRegularExpression`.
    var fullNSRange: NSRange { NSRange(location: 0, length: utf16.count) }
}

extension NSRegularExpression {
    /// Replace-all where each match's replacement is computed (Dart `replaceAllMapped`). The replacement is literal.
    func replacingMatches(in text: String, _ replacement: (NSTextCheckingResult) -> String) -> String {
        let found = matches(in: text, range: text.fullNSRange)
        if found.isEmpty { return text }
        let ns = text as NSString
        var out = ""
        var position = 0
        for match in found {
            out += ns.substring(with: NSRange(location: position, length: match.range.location - position))
            out += replacement(match)
            position = NSMaxRange(match.range)
        }
        return out + ns.substring(from: position)
    }

    func hasMatch(_ text: String) -> Bool {
        firstMatch(in: text, range: text.fullNSRange) != nil
    }
}

extension NSTextCheckingResult {
    /// Capture group `n` of a match in `text`, nil when the group did not take part.
    func group(_ n: Int, in text: String) -> String? {
        let r = range(at: n)
        return r.location == NSNotFound ? nil : (text as NSString).substring(with: r)
    }
}
