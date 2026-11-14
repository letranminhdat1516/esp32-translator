// Used by build.sh only when this Mac runs macOS < 26.4: the app's Translate/Translator.swift calls
// TranslationSession(installedSource:target:preferredStrategy:), which the compiler only allows with a 26.4
// deployment target, and a binary built for 26.4 does not launch on an older macOS. Same class, same API, same
// session setup; .lowLatency is used when the running OS has it (the report says which).
import Foundation
import Translation

final class Translator: @unchecked Sendable {
    private let session: TranslationSession
    static var strategy = "default (preferredStrategy needs macOS 26.4)"

    init(from source: Locale.Language, to target: Locale.Language) {
        if #available(macOS 26.4, iOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            Translator.strategy = ".lowLatency"
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }
}
