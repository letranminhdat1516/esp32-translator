import Foundation

/// Cheap text fix-ups around the Vietnamese recognizer and the VI→EN translator, now data: the rules are the
/// `recognition` and `beforeTranslation` lists of the Vietnamese language pack (`shared/languages/vi.json`), applied
/// by `RuleEngine`. Kept as a thin wrapper so the EN↔VI app (ConversationEngine, TurnAssembler) is unchanged.
enum VietnameseFixup {
    /// Loanwords and brand names the recognizer spells as Vietnamese syllables. Applied to the recognized text itself
    /// (shown and translated).
    static func fixLoanwords(_ text: String) -> String {
        engine.fixRecognition(text)
    }

    /// The text given to the VI→EN translator: loanwords fixed, vocatives dropped, service phrases and a few idioms
    /// put in plain Vietnamese. Never shown.
    static func forTranslation(_ text: String) -> String {
        engine.forTranslation(text)
    }

    /// The vi pack's rules. A missing or broken pack is a build error (the pack is a bundle resource); in release it
    /// degrades to no fix-ups rather than a crash.
    private static let engine: RuleEngine = {
        do {
            return try RuleEngine(pack: SharedResources.languagePack(LanguageCatalog.homeCode))
        } catch {
            assertionFailure("vi language pack: \(error)")
            return try! RuleEngine(recognition: [], beforeTranslation: [])
        }
    }()
}
