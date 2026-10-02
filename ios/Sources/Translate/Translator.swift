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

/// Runs only the latest translation request and drops stale ones.
/// Used for live subtitles: the text changes constantly and only the current sentence matters.
@MainActor
final class LatestWinsTranslator {
    private let translator: Translator
    private let onResult: (String) -> Void
    private var running = false
    private var pending: String?

    init(translator: Translator, onResult: @escaping (String) -> Void) {
        self.translator = translator
        self.onResult = onResult
    }

    func submit(_ text: String) {
        pending = text
        guard !running else { return }
        running = true
        Task {
            while let next = pending {
                pending = nil
                if let out = try? await translator.translate(next) { onResult(out) }
            }
            running = false
        }
    }
}
