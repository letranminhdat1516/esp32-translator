import Foundation
import Translation

/// Offline translation with Apple's on-device models.
actor Translator {
    private let session: TranslationSession

    init(from source: Locale.Language, to target: Locale.Language) {
        if #available(iOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    static func isInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }
}
