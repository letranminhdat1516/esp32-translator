import Foundation
import Synchronization

// Contract: shared/fixtures/text_pipeline.json.

/// Which way a phrase is translated.
enum Direction: Sendable {
    /// The wearer speaks the home language; the other language comes out.
    case mine
    /// The other person speaks; the home language comes out.
    case theirs
}

/// A phrase ready for the translator.
struct Prepared: Hashable, Sendable {
    /// What to translate: rules applied, protected terms replaced by placeholders.
    let text: String
    /// The same text with the rules applied and the terms in place (the fallback request when a placeholder is
    /// lost).
    let unmasked: String
    /// Language code the translation is into.
    let targetCode: String
    /// The placeholders and what they stand for.
    let masked: Masked
}

/// Everything done to a phrase around the translator: the source language's rules (recognition fixes, vocatives and
/// idioms rewritten, R9, R13), then protected terms (R10, R11) swapped for placeholders; and the reverse after
/// translation.
///
/// Rules and built-in terms come from the language packs; glossary terms are the user's and win over built-in terms
/// spelled the same. The placeholder shape is pipeline configuration, per target language (`placeholders`), with
/// `defaultPlaceholder` otherwise.
final class TextPipeline: Sendable {
    /// The home language (Vietnamese).
    let home: LanguagePack
    /// The language picked for the other person.
    let other: LanguagePack
    let glossary: [Term]
    /// Placeholder shape per target language code (`{n}` = the number).
    let placeholders: [String: String]
    let defaultPlaceholder: String

    private let homeRules: RuleEngine
    private let otherRules: RuleEngine
    private let protector = TermProtector()
    private let lost = Mutex(0)

    /// Throws when a pack rule does not compile.
    init(home: LanguagePack, other: LanguagePack, glossary: [Term] = [], placeholders: [String: String] = [:],
         defaultPlaceholder: String = TermProtector.defaultPlaceholder) throws {
        self.home = home
        self.other = other
        self.glossary = glossary
        self.placeholders = placeholders
        self.defaultPlaceholder = defaultPlaceholder
        homeRules = try RuleEngine(pack: home)
        otherRules = try RuleEngine(pack: other)
    }

    /// Placeholders lost by the translator so far (the unmasked fallback ran).
    var lostPlaceholders: Int { lost.withLock { $0 } }

    /// Prepares `text` for translation in `direction`. Throws `TermProtector.InvalidPlaceholder` for a bad
    /// placeholder shape.
    func prepare(_ text: String, _ direction: Direction) throws -> Prepared {
        let (rules, target) = switch direction {
        case .mine: (homeRules, other.code)
        case .theirs: (otherRules, home.code)
        }
        let ruled = rules.forTranslation(text)
        let masked = try protector.mask(ruled, terms: glossary + home.terms + other.terms, target: target,
                                        placeholder: placeholders[target] ?? defaultPlaceholder)
        return Prepared(text: masked.text, unmasked: ruled, targetCode: target, masked: masked)
    }

    /// Puts the protected terms back into `translated`. Nil when a placeholder did not survive translation.
    func finish(_ translated: String, _ prepared: Prepared) -> String? {
        protector.restore(translated, prepared.masked)
    }

    /// Repairs a translation of the unmasked text: each protected term found as written in the source (whole words,
    /// same case) is replaced by its fixed translation.
    func repair(_ translated: String, _ prepared: Prepared) -> String {
        var out = translated
        for (surface, output) in prepared.masked.replacements where surface != output {
            out = TermProtector.wholeWordRegex(surface, caseSensitive: true).replacingMatches(in: out) { _ in output }
        }
        return out
    }

    /// Prepare, translate with the injected `translator`, finish. If the translator drops a placeholder, the
    /// unmasked text is translated instead and fixed terms are repaired where found (counted in `lostPlaceholders`).
    /// Errors of the translator reach the caller.
    func translate(_ text: String, _ direction: Direction,
                   translator: (String) async throws -> String) async throws -> String {
        if text.dartTrimmed.isEmpty { return "" }
        let prepared = try prepare(text, direction)
        let translated = try await translator(prepared.text)
        if let restored = finish(translated, prepared) { return restored }
        lost.withLock { $0 += 1 }
        return repair(try await translator(prepared.unmasked), prepared)
    }
}
