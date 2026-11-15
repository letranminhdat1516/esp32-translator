import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// The refine step's model on device: Apple's FoundationModels system language model (Apple Intelligence, iOS 26).
// Checked in the iOS 26.4 SDK: `SystemLanguageModel.default.availability` (.available / .unavailable(reason)),
// `supportsLocale(_:)`, a 4096-token `contextSize`, `GenerationOptions(sampling: .greedy, maximumResponseTokens:)`,
// `LanguageModelSession.prewarm()`. Vietnamese, English, Japanese, Korean, Chinese, French, German and Spanish are
// supported; Thai is not (docs/translation-refine.md).

extension TranslationRefiner {
    /// The on-device refiner, or nil where FoundationModels does not exist (the model's own availability is checked
    /// per request: Apple Intelligence can be turned on or off, and the model downloaded, while the app runs).
    static func onDevice() -> TranslationRefiner? {
        #if canImport(FoundationModels)
        return TranslationRefiner(model: FoundationRefineModel())
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
/// `RefineModel` over `SystemLanguageModel.default`. Each request gets a fresh session (the conversation is in the
/// prompt; a kept session would fill its context window); one session is prewarmed ahead for the next request.
final class FoundationRefineModel: RefineModel, @unchecked Sendable {
    private let model = SystemLanguageModel.default
    private let lock = NSLock()
    /// A session made and prewarmed ahead of the next request (guarded by `lock`)
    private var spare: LanguageModelSession?
    /// Spoken phrases are short; a fix longer than this is rejected by `RefineCheck` anyway
    private let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)

    func supports(_ code: String) -> Bool {
        model.availability == .available && model.supportsLocale(Locale(identifier: code))
    }

    func prewarm() {
        guard model.availability == .available else { return }
        lock.withLock {
            if spare == nil { spare = makeSession(RefinePrompt.instructions) }
        }
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        let warm = lock.withLock {
            defer { spare = nil }
            return spare
        }
        let session = (instructions == RefinePrompt.instructions ? warm : nil) ?? makeSession(instructions)
        // The next request starts on a warm session too
        prewarm()
        return try await session.respond(to: prompt, options: options).content
    }

    private func makeSession(_ instructions: String) -> LanguageModelSession {
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm()
        return session
    }
}
#endif
