import AVFAudio
import Foundation
import Speech
import Translation

/// `RecognizerKind` names in wire form. iOS offers only the OS on-device recognizers in Phase 1 (Whisper on iOS
/// is Phase 2 or later).
enum RecognizerKinds {
    static let onDevice = RecognizerKind.osOnDevice.rawValue
}

/// `capabilities(home)` from what the device reports (R2): per pack code, the on-device recognizers
/// (SpeechTranscriber or DictationTranscriber support the locale), the languages that translate both ways with
/// home (LanguageAvailability, installed or downloadable), and whether home has a TTS voice. Device locales and
/// languages are keyed by pack code through `EngineLocales` ("zh_CN" and "zh" are "zh-Hans"), the key
/// `LanguageCatalog` looks up. Whisper is not offered on iOS in Phase 1.
enum CapabilitiesAssembly {
    typealias Directions = (toHome: LanguageAvailability.Status, fromHome: LanguageAvailability.Status)

    /// `translation` is keyed by the language identifiers the framework reports ("zh", "zh-TW", "en"); several
    /// that map to one pack code translate when any of them does both ways.
    static func assemble(home: String, speechLocales: [Locale], dictationLocales: [Locale],
                         translation: [String: Directions], voices: [String],
                         locales: EngineLocales = EngineLocales()) -> CapabilitiesMsg {
        let languages = Set((speechLocales + dictationLocales).map { locales.code(for: $0) })
        let recognizers = languages.sorted().map {
            RecognizerEntryMsg(language: $0, kinds: [RecognizerKinds.onDevice])
        }
        var translatable = Set(translation
            .filter { $0.value.toHome != .unsupported && $0.value.fromHome != .unsupported }
            .map { locales.code(for: Locale.Language(identifier: $0.key)) })
        translatable.remove(home)
        if !translatable.isEmpty { translatable.insert(home) }
        let homeCode = EngineMapping.languageCode(Locale(identifier: home))
        let voice = voices.contains { EngineMapping.languageCode(Locale(identifier: $0)) == homeCode }
        return CapabilitiesMsg(recognizers: recognizers, translatable: translatable.sorted(), vietnameseVoice: voice)
    }

    /// Asks the frameworks; no downloads. Safe off the main thread.
    static func gather(home: String, locales: EngineLocales = EngineLocales()) async -> CapabilitiesMsg {
        let speech = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictation = await DictationTranscriber.supportedLocales
        let availability = LanguageAvailability()
        let homeLanguage = locales.translationLanguage(home)
        var translation: [String: Directions] = [:]
        for language in await availability.supportedLanguages {
            let id = language.maximalIdentifier
            guard locales.code(for: language) != home, translation[id] == nil else { continue }
            translation[id] = (toHome: await availability.status(from: language, to: homeLanguage),
                               fromHome: await availability.status(from: homeLanguage, to: language))
        }
        let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        return assemble(home: home, speechLocales: speech, dictationLocales: dictation, translation: translation,
                        voices: voices, locales: locales)
    }
}

/// `missing(pair)`: what must be downloaded before `start` can run the pair (R3). Unsupported items are left
/// out (they cannot be downloaded; `capabilities(home)` already does not offer them).
enum MissingAssembly {
    /// `speech`: per pair language, the asset status of its recognizer, nil when it has none.
    /// `translation`: per direction, the model status.
    static func assemble(pair: PairMsg, speech: [(language: String, status: AssetInventory.Status?)],
                         translation: [(from: String, to: String, status: LanguageAvailability.Status)],
                         hasVoice: Bool) -> [MissingMsg] {
        var missing: [MissingMsg] = []
        for (language, status) in speech {
            if let status, status == .supported || status == .downloading {
                missing.append(MissingMsg(kind: .speechModel, language: language))
            }
        }
        for (from, to, status) in translation where status == .supported {
            missing.append(MissingMsg(kind: .translation, language: pair.other, from: from, to: to))
        }
        if !hasVoice { missing.append(MissingMsg(kind: .ttsVoice, language: pair.home)) }
        return missing
    }

    /// Asks the frameworks; no downloads. Safe off the main thread.
    static func gather(_ pair: PairMsg, locales: EngineLocales = EngineLocales()) async -> [MissingMsg] {
        var speech: [(language: String, status: AssetInventory.Status?)] = []
        for language in [pair.other, pair.home] {
            let recognizer = await LiveTranscriber.resolve(locales.speechLocale(language).identifier)
            speech.append((language, await recognizer?.assetStatus))
        }
        let availability = LanguageAvailability()
        let other = locales.translationLanguage(pair.other), home = locales.translationLanguage(pair.home)
        let translation = [
            (from: pair.other, to: pair.home, status: await availability.status(from: other, to: home)),
            (from: pair.home, to: pair.other, status: await availability.status(from: home, to: other)),
        ]
        return assemble(pair: pair, speech: speech, translation: translation,
                        hasVoice: EngineMapping.bestVoice(pair.home) != nil)
    }
}

/// The last capabilities per home language. `capabilities(home)` is async: a caller with no cached
/// value suspends (no thread waits) until the one gather in flight for that home finishes. The first framework
/// query in a fresh process can be slow (more than 20 s once on the Mac host, cold daemons).
final class CapabilitiesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (home: String, value: CapabilitiesMsg)?
    private var inFlight: (home: String, id: Int, task: Task<CapabilitiesMsg, Never>)?
    private var nextID = 0
    /// Bumped by `invalidate`: a gather started before it does not store its (stale) result
    private var epoch = 0
    private let gather: @Sendable (String) async -> CapabilitiesMsg

    init(gather: @escaping @Sendable (String) async -> CapabilitiesMsg = { await CapabilitiesAssembly.gather(home: $0) }) {
        self.gather = gather
    }

    /// Starts a gather for `home` unless one is already running for it
    func refresh(home: String) {
        _ = startGather(home: home)
    }

    func invalidate() {
        lock.withLock {
            cached = nil
            inFlight = nil
            epoch += 1
        }
    }

    /// The cached value for `home`, else the result of the gather in flight for it (started if none)
    func get(home: String) async -> CapabilitiesMsg {
        if let hit = lock.withLock({ cached }), hit.home == home { return hit.value }
        return await startGather(home: home).value
    }

    private func startGather(home: String) -> Task<CapabilitiesMsg, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = inFlight, running.home == home { return running.task }
        nextID += 1
        let id = nextID, started = epoch
        let task = Task.detached { [self] in
            let value = await gather(home)
            lock.withLock {
                if epoch == started { cached = (home, value) }
                if inFlight?.id == id { inFlight = nil }
            }
            return value
        }
        inFlight = (home, id, task)
        return task
    }
}
