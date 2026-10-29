import Foundation

// Port of app/lib/core/rule_engine.dart; contract: shared/fixtures/rules.json (see shared/fixtures/README.md).

/// A `Rule` with its regular expressions compiled.
struct CompiledRule: @unchecked Sendable {  // NSRegularExpression is immutable and thread safe
    let id: String
    let regex: NSRegularExpression
    let template: String
    /// The rule applies only when the whole text also matches this (context, e.g. talk about a price).
    let context: NSRegularExpression?

    init(_ rule: Rule) throws {
        // Whole words only: no letter or digit may touch the match. The patterns in the pack data stay free of
        // bounds; the engine adds them. With `atClauseStart` the match must begin the text or follow , . ! ? (the
        // template gets the punctuation back as $1).
        let start = rule.atClauseStart ? "(^|[,.!?])\\s*" : "(?<![\\p{L}\\p{N}])"
        let bounded = "\(start)(?:\(RuleEngine.portablePattern(rule.pattern)))(?![\\p{L}\\p{N}])"
        id = rule.id
        regex = try NSRegularExpression(pattern: bounded, options: [.caseInsensitive])
        template = rule.template
        context = try rule.context.map {
            try NSRegularExpression(pattern: RuleEngine.portablePattern($0), options: [.caseInsensitive])
        }
    }

    private static let group = try! NSRegularExpression(pattern: "\\$([0-9])")

    /// `$n` = capture group n; empty when the group did not take part or does not exist. Nothing else is special.
    private func expand(_ match: NSTextCheckingResult, in text: String) -> String {
        Self.group.replacingMatches(in: template) { g in
            let n = Int(g.group(1, in: template)!)!
            return n < match.numberOfRanges ? (match.group(n, in: text) ?? "") : ""
        }
    }

    /// Applies the rule to `text`.
    func apply(_ text: String) -> String {
        if let context, !context.hasMatch(text) { return text }
        return regex.replacingMatches(in: text) { expand($0, in: text) }
    }
}

/// Applies a language pack's rules, which are data, to text around the recognizer and the translator.
///
/// Two lists, both whole-word and case-insensitive:
/// - `recognition` rules fix what the recognizer mishears (loanwords and brand names it spells as native syllables).
///   Applied to the recognized text itself (`fixRecognition`: shown and translated).
/// - `beforeTranslation` rules rewrite text only for the translator (`forTranslation`): vocatives dropped, service
///   phrases and idioms put in plain words. Never shown.
struct RuleEngine: Sendable {
    let recognitionRules: [CompiledRule]
    let beforeRules: [CompiledRule]

    init(recognition: [Rule], beforeTranslation: [Rule]) throws {
        recognitionRules = try recognition.map(CompiledRule.init)
        beforeRules = try beforeTranslation.map(CompiledRule.init)
    }

    init(pack: LanguagePack) throws {
        try self.init(recognition: pack.recognition, beforeTranslation: pack.beforeTranslation)
    }

    /// Fixes recognizer mishearings. A pack without recognition rules returns `text` untouched.
    func fixRecognition(_ text: String) -> String {
        Self.apply(recognitionRules, to: text)
    }

    /// The text given to the translator: recognition fixes, then the before-translation rules, with the gaps they
    /// leave tidied. If the rules leave no letter at all (only vocatives were spoken) the recognition-fixed text is
    /// kept rather than translating nothing. A pack without before-translation rules returns `fixRecognition`'s
    /// result.
    func forTranslation(_ text: String) -> String {
        let fixed = fixRecognition(text)
        if beforeRules.isEmpty { return fixed }
        let rewritten = Self.tidy(Self.apply(beforeRules, to: fixed), original: text)
        return rewritten.unicodeScalars.contains(where: \.isLetterCategory) ? rewritten : fixed
    }

    /// A pack pattern in ICU's dialect: `\d` means ASCII digits only, as in Dart and JavaScript (ICU would take every
    /// Unicode decimal digit). `\d` becomes `[0-9]`, or `0-9` inside a character class, and `\D` outside a class
    /// becomes `[^0-9]`; everything else is kept. Remaining ICU differences (full case folding, `$` before a final
    /// line terminator) are listed in shared/fixtures/README.md; the packs do not rely on them.
    static func portablePattern(_ pattern: String) -> String {
        var out = ""
        var inClass = false
        var i = pattern.unicodeScalars.makeIterator()
        while let c = i.next() {
            switch c {
            case "\\":
                guard let next = i.next() else {
                    out.unicodeScalars.append(c)
                    break
                }
                if next == "d" {
                    out += inClass ? "0-9" : "[0-9]"
                } else if next == "D" && !inClass {
                    out += "[^0-9]"  // inside a class it has no equivalent; the portable-syntax lint forbids \D
                } else {
                    out.unicodeScalars.append(c)
                    out.unicodeScalars.append(next)
                }
            case "[" where !inClass:
                inClass = true
                out.unicodeScalars.append(c)
                // A `]` (or `^]`) right after the opening bracket is a literal in ICU; keep it inside the class.
                var lookahead = i
                if lookahead.next() == "^" { out += "^"; i = lookahead }
                lookahead = i
                if lookahead.next() == "]" { out += "]"; i = lookahead }
            case "]" where inClass:
                inClass = false
                out.unicodeScalars.append(c)
            default:
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private static func apply(_ rules: [CompiledRule], to text: String) -> String {
        if rules.isEmpty { return text }
        var s = text.nfc
        for rule in rules {
            s = rule.apply(s)
        }
        return s
    }

    /// JavaScript's (and Dart's) `\s`, which differs from ICU's in U+000B and U+FEFF.
    private static let space = "\\t\\n\\x{0B}\\f\\r\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
    private static let spaces = try! NSRegularExpression(pattern: "[\(space)]+")
    private static let spaceBeforePunct = try! NSRegularExpression(pattern: "[\(space)]+([,.!?])")
    private static let commaAfterPunct = try! NSRegularExpression(pattern: "([,.!?])[,]+")
    private static let leadingJunk = try! NSRegularExpression(pattern: "^[\(space),.!]+")
    private static let trailingSpace = try! NSRegularExpression(pattern: "[\(space)]+$")

    /// Removes the gaps and stray punctuation left by deletions, and capitalizes a sentence start.
    private static func tidy(_ text: String, original: String) -> String {
        var s = spaces.replacingMatches(in: text) { _ in " " }
        s = spaceBeforePunct.replacingMatches(in: s) { $0.group(1, in: s)! }
        s = commaAfterPunct.replacingMatches(in: s) { $0.group(1, in: s)! }
        s = leadingJunk.replacingMatches(in: s) { _ in "" }
        s = trailingSpace.replacingMatches(in: s) { _ in "" }
        if let first = s.first, let originalFirst = original.first,
           isLower(String(first)), isUpper(String(originalFirst)) {
            s = String(first).uppercased() + s.dropFirst()
        }
        return s
    }

    private static func isLower(_ g: String) -> Bool { g.uppercased() != g && g.lowercased() == g }

    private static func isUpper(_ g: String) -> Bool { g.lowercased() != g && g.uppercased() == g }
}
