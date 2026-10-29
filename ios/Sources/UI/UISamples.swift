#if DEBUG
import Foundation

// Sample data for the SwiftUI previews.

extension UIState {
    static let sampleNames = ["vi": "Tiếng Việt", "en": "English", "ja": "日本語", "fr": "Français", "ko": "한국어"]

    static var samplePacks: [LanguagePack] {
        [
            LanguagePack(code: "en", appleLocale: "en-US", androidLocale: "en-US", whisperCode: "en", label: "English",
                         labelLatin: "English", script: .latin),
            LanguagePack(code: "ja", appleLocale: "ja-JP", androidLocale: "ja-JP", whisperCode: "ja", label: "日本語",
                         labelLatin: "Japanese", script: .cjk),
            LanguagePack(code: "ko", appleLocale: "ko-KR", androidLocale: "ko-KR", whisperCode: "ko", label: "한국어",
                         labelLatin: "Korean", script: .hangul),
        ]
    }

    static let sampleMissing = [
        MissingMsg(kind: .speechModel, language: "ja"),
        MissingMsg(kind: .translation, language: "ja", from: "ja", to: "vi"),
        MissingMsg(kind: .translation, language: "ja", from: "vi", to: "ja"),
    ]

    /// The session is choosing a language.
    static func sampleChoosing() -> UIState {
        let ui = UIState()
        ui.session = .choosing()
        ui.offeredPacks = samplePacks
        ui.languageNames = sampleNames
        ui.languageCode = "en"
        return ui
    }

    /// Choosing, with a language that works only online and one that could with the opt-in.
    static func sampleOnlineOptIn() -> UIState {
        let ui = sampleChoosing()
        ui.onlineCodes = ["ko"]
        ui.onlineAllowed = ["ko"]
        ui.onlineCandidates = [
            LanguagePack(code: "fr", appleLocale: "fr-FR", androidLocale: "fr-FR", whisperCode: "fr", label: "Français",
                         labelLatin: "Français", script: .latin),
        ]
        return ui
    }

    /// Running, with lines, an unclear line, partials and every chip.
    static func sampleRunning() -> UIState {
        let ui = sampleChoosing()
        ui.session = .running("ja")
        ui.languageCode = "ja"
        ui.languageLabel = "日本語"
        ui.listening = true
        ui.board = .off
        ui.online = true
        ui.micRoute = .phoneMic
        ui.ttsVoiceMissing = true
        let now = Date()
        ui.lines = [
            UILine(id: "1", mine: false, source: "駅はどこですか", target: "Ga ở đâu vậy?", at: now - 30),
            UILine(id: "2", mine: true, source: "Đi thẳng rồi rẽ trái.", target: "まっすぐ行って左に曲がってください。",
                   at: now - 20),
            UILine(id: "3", mine: false, source: "ありがとう", target: "Cảm ơn", unclear: true, at: now - 10),
        ]
        ui.theirPartial = "すみません"
        return ui
    }

    /// A glossary; every add or edit is rejected with `rejecting` when given.
    static func sampleGlossary(rejecting message: String? = nil) -> UIState {
        let ui = UIState()
        ui.glossaryTerms = [
            Term(id: "1", text: "Bến Thành", variants: ["Ben Thanh"]),
            Term(id: "2", text: "Chợ Bến Thành"),
            Term(id: "3", text: "Cicca", origin: .builtIn),
        ]
        if let message {
            ui.glossaryAdd = { _ in throw GlossaryValidationError(message: message) }
            ui.glossaryUpdate = { _, _ in throw GlossaryValidationError(message: message) }
        }
        return ui
    }
}
#endif
