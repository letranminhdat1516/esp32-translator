import Foundation
import TermHarnessKit
import Translation

/// Apple Translation, set up like the app's `Translator` (ios/Sources/Translate/Translator.swift): installed models
/// only, low-latency strategy where the OS has it. That file is not linked because its 26.4 initializer is marked
/// iOS-only and this tool targets macOS 26.0. Language codes map to the pack's `appleLocale`
/// (shared/languages/<code>.json); a code without a pack is used as is.
actor AppleTranslator: Translating {
    private let languagesDir: URL
    private var sessions: [String: TranslationSession] = [:]

    init(languages: URL) { languagesDir = languages }

    private func language(_ code: String) -> Locale.Language {
        let pack = languagesDir.appendingPathComponent("\(code).json")
        if let data = try? Data(contentsOf: pack),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let locale = json["appleLocale"] as? String {
            return Locale.Language(identifier: locale)
        }
        return Locale.Language(identifier: code)
    }

    /// Throws listing every pair whose models are not installed (System Settings › General › Language & Region ›
    /// Translation Languages on the Mac; the app's download flow on the iPhone).
    func checkInstalled(_ pairs: Set<[String]>) async throws {
        var missing: [String] = []
        for pair in pairs.sorted(by: { $0.joined() < $1.joined() }) {
            let status = await LanguageAvailability().status(from: language(pair[0]), to: language(pair[1]))
            if status != .installed { missing.append("\(pair[0])>\(pair[1]) (\(status))") }
        }
        if !missing.isEmpty {
            throw HarnessError(description: "translation models not installed: \(missing.joined(separator: ", "))")
        }
    }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let key = "\(from)>\(to)"
        let session: TranslationSession
        if let existing = sessions[key] {
            session = existing
        } else {
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: language(from), target: language(to),
                                             preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: language(from), target: language(to))
            }
            sessions[key] = session
        }
        return try await session.translate(text).targetText
    }
}
