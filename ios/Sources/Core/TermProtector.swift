import Foundation

// Contract: shared/fixtures/terms.json (Review Focus 3).

/// Text with its protected terms swapped for placeholders, and what each placeholder stands for. Made by
/// `TermProtector.mask`.
struct Masked: Hashable, Sendable {
    /// The text to translate.
    let text: String
    /// Placeholder numbers in the order they were issued.
    fileprivate let numbers: [Int]
    /// Placeholder number → text it turns back into.
    fileprivate let outputs: [Int: String]
    /// Placeholder number → the form found in the source text.
    fileprivate let surfaces: [Int: String]
    /// Placeholder number → how many times it occurs in `text`.
    fileprivate let counts: [Int: Int]
    /// Numbers the source text itself already used; they are not ours.
    fileprivate let taken: Set<Int>
    fileprivate let prefix: String
    fileprivate let suffix: String

    /// No term was found: `text` is the input and nothing needs restoring.
    var isEmpty: Bool { outputs.isEmpty }

    /// (source form, replacement) of every placeholder, in issue order; used to repair a translation that lost its
    /// placeholders.
    var replacements: [(surface: String, output: String)] {
        numbers.map { (surfaces[$0]!, outputs[$0]!) }
    }
}

/// Keeps names, brands, places and glossary terms intact through translation (R10): each term found in the source
/// is replaced by a placeholder such as `Zorvik1`, the text is translated, and the placeholders are swapped for the
/// term itself or its fixed translation for the target language.
///
/// Terms (and their variants) are matched literally, longest first (UTF-16 length), and text already taken by a
/// longer term is never masked again. Latin text matches case-insensitively (the spoken form is kept when restored),
/// other scripts exactly. Terms made of letters or digits only match whole words, except in scripts written without
/// spaces (CJK, kana, Hangul, Thai), where a term may sit inside a longer run of text.
struct TermProtector: Sendable {
    static let defaultPlaceholder = "Zorvik{n}"

    /// The placeholder shape does not hold `{n}` exactly once with some text around it.
    struct InvalidPlaceholder: Error, Equatable, CustomStringConvertible {
        let placeholder: String
        let reason: String
        var description: String { "invalid placeholder \"\(placeholder)\": \(reason)" }
    }

    private static let nonLatinLetter = try! NSRegularExpression(pattern: "(?!\\p{Script=Latin})\\p{L}")

    /// Scripts written without spaces: no word bound at an edge in these (U+0E00–U+0E7F, U+1100–U+11FF,
    /// U+3040–U+30FF, U+3130–U+318F, U+3400–U+4DBF, U+4E00–U+9FFF, U+AC00–U+D7A3, U+F900–U+FAFF).
    private static func isUnspaced(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0E00...0x0E7F, 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7A3, 0xF900...0xFAFF: true
        default: false
        }
    }

    init() {}

    /// Replaces the terms found in `text` with placeholders. `placeholder` holds `{n}` once, replaced by 1, 2, … in
    /// order of appearance (numbers already used by the text itself are skipped). `target` picks each term's fixed
    /// translation. Throws `InvalidPlaceholder` for a bad shape.
    func mask(_ text: String, terms: [Term], target: String,
              placeholder: String = TermProtector.defaultPlaceholder) throws -> Masked {
        let parts = placeholder.components(separatedBy: "{n}")
        guard parts.count == 2 else {
            throw InvalidPlaceholder(placeholder: placeholder, reason: "must contain {n} exactly once")
        }
        let (prefix, suffix) = (parts[0], parts[1])
        guard !(prefix.isEmpty && suffix.isEmpty) else {
            throw InvalidPlaceholder(placeholder: placeholder, reason: "must have text around {n}")
        }

        let s = text.nfc
        let ns = s as NSString
        var candidates: [(surface: String, term: Term)] = []
        var seen = Set<String>()  // all NFC here, so canonical equality is exact equality
        for term in terms {
            for surface in [term.text] + term.variants {
                let c = surface.nfc
                if !c.isEmpty && seen.insert(c).inserted { candidates.append((c, term)) }
            }
        }
        // Longest first in UTF-16 units; ties keep their input order.
        let ordered = candidates.enumerated().sorted { a, b in
            let (la, lb) = (a.element.surface.utf16.count, b.element.surface.utf16.count)
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)

        let lower = s.lowercased() as NSString
        var spans: [(range: NSRange, term: Term, matched: String)] = []
        for (candidate, term) in ordered {
            if lower.range(of: candidate.lowercased(), options: .literal).location == NSNotFound { continue }
            for m in Self.wholeWordRegex(candidate).matches(in: s, range: s.fullNSRange) {
                if spans.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) { continue }
                spans.append((m.range, term, ns.substring(with: m.range)))
            }
        }
        if spans.isEmpty {
            return Masked(text: s, numbers: [], outputs: [:], surfaces: [:], counts: [:], taken: [], prefix: prefix,
                          suffix: suffix)
        }
        spans.sort { $0.range.location < $1.range.location }

        // Numbers the text already uses ("Zorvik1" typed by the speaker) are skipped, so they cannot be mistaken for
        // a placeholder.
        let slot = Self.slotRegex(prefix, suffix)
        let taken = Set(slot.matches(in: s, range: s.fullNSRange).compactMap { Int($0.group(1, in: s)!) })
        var next = 0
        func allocate() -> Int {
            repeat { next += 1 } while taken.contains(next)
            return next
        }

        // One placeholder per fixed translation (all spoken forms of a term share it) or per distinct spoken form.
        var numberByKey: [String: Int] = [:]
        var numbers: [Int] = []
        var outputs: [Int: String] = [:]
        var surfaces: [Int: String] = [:]
        var counts: [Int: Int] = [:]
        var out = ""
        var position = 0
        for span in spans {
            let fixed = span.term.fixed[target]
            let key = fixed != nil ? "fixed:\(span.term.id)" : "text:\(span.matched)"
            let n: Int
            if let existing = numberByKey[key] {
                n = existing
            } else {
                n = allocate()
                numberByKey[key] = n
                numbers.append(n)
                outputs[n] = fixed ?? span.matched
                surfaces[n] = span.matched
            }
            counts[n, default: 0] += 1
            out += ns.substring(with: NSRange(location: position, length: span.range.location - position))
            out += "\(prefix)\(n)\(suffix)"
            position = NSMaxRange(span.range)
        }
        out += ns.substring(from: position)
        return Masked(text: out, numbers: numbers, outputs: outputs, surfaces: surfaces, counts: counts, taken: taken,
                      prefix: prefix, suffix: suffix)
    }

    /// Puts the terms back into `translated`. Returns nil when a placeholder did not survive translation (lost,
    /// duplicated, or one we never issued appeared); the caller then translates the unmasked text and repairs fixed
    /// terms where found.
    func restore(_ translated: String, _ m: Masked) -> String? {
        if m.isEmpty { return translated }
        var found: [Int: Int] = [:]
        var invented = false
        let restored = Self.slotRegex(m.prefix, m.suffix).replacingMatches(in: translated) { match in
            let whole = match.group(0, in: translated)!
            guard let n = Int(match.group(1, in: translated)!) else {
                invented = true  // a number too large to be ours or the source's
                return whole
            }
            guard let output = m.outputs[n] else {
                if !m.taken.contains(n) { invented = true }
                return whole
            }
            found[n, default: 0] += 1
            return output
        }
        if invented { return nil }
        for (n, count) in m.counts where found[n] != count { return nil }
        return restored
    }

    private static func slotRegex(_ prefix: String, _ suffix: String) -> NSRegularExpression {
        let p = NSRegularExpression.escapedPattern(for: prefix)
        let s = NSRegularExpression.escapedPattern(for: suffix)
        return try! NSRegularExpression(pattern: "\(p)([0-9]+)\(s)", options: [.caseInsensitive])
    }

    /// Matches `candidate` literally, as a whole word where its edges are letters or digits. Case-insensitive for
    /// Latin unless `caseSensitive`; a candidate with a non-Latin letter is case-sensitive by default.
    static func wholeWordRegex(_ candidate: String, caseSensitive: Bool? = nil) -> NSRegularExpression {
        func needsBound(_ edge: Character?) -> Bool {
            guard let edge else { return false }
            let scalars = edge.unicodeScalars
            return scalars.contains { $0.isLetterCategory || $0.isNumberCategory } && !scalars.contains(where: isUnspaced)
        }
        let before = needsBound(candidate.first) ? "(?<![\\p{L}\\p{N}])" : ""
        let after = needsBound(candidate.last) ? "(?![\\p{L}\\p{N}])" : ""
        let sensitive = caseSensitive ?? nonLatinLetter.hasMatch(candidate)
        return try! NSRegularExpression(pattern: before + NSRegularExpression.escapedPattern(for: candidate) + after,
                                        options: sensitive ? [] : [.caseInsensitive])
    }
}
