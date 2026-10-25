import AVFAudio
import Foundation
import Speech
import Translation

/// The home language before Dart has sent a pair. Vietnamese is always the home side (constraints), and
/// `capabilities()` has no pair argument but must report translation with it and its TTS voice. A language
/// code, not a locale (R16): the region comes from the device. Track E uses the same constant on Android.
let defaultHomeLanguage = "vi"

/// `RecognizerKind` names as Dart knows them. iOS offers only the OS on-device recognizers in Phase 1
/// (Whisper on iOS is Phase 2 or later).
enum RecognizerKinds {
    static let onDevice = "osOnDevice"
}

/// `capabilities()` from what the device reports (R2): per language code, the on-device recognizers
/// (SpeechTranscriber or DictationTranscriber support the locale), the languages that translate both ways with
/// home (LanguageAvailability, installed or downloadable), and whether home has a TTS voice.
/// Whisper is not offered on iOS in Phase 1.
enum CapabilitiesAssembly {
    typealias Directions = (toHome: LanguageAvailability.Status, fromHome: LanguageAvailability.Status)

    static func assemble(home: String, speechLocales: [Locale], dictationLocales: [Locale],
                         translation: [String: Directions], voices: [String]) -> CapabilitiesMsg {
        let languages = Set((speechLocales + dictationLocales).map(EngineMapping.languageCode))
        let recognizers = languages.sorted().map {
            RecognizerEntryMsg(language: $0, kinds: [RecognizerKinds.onDevice])
        }
        var translatable = translation
            .filter { $0.key != home && $0.value.toHome != .unsupported && $0.value.fromHome != .unsupported }
            .map(\.key)
        if !translatable.isEmpty { translatable.append(home) }
        let homeCode = EngineMapping.languageCode(Locale(identifier: home))
        let voice = voices.contains { EngineMapping.languageCode(Locale(identifier: $0)) == homeCode }
        return CapabilitiesMsg(recognizers: recognizers, translatable: translatable.sorted(), vietnameseVoice: voice)
    }

    /// Asks the frameworks; no downloads. Safe off the main thread.
    static func gather(home: String) async -> CapabilitiesMsg {
        let speech = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictation = await DictationTranscriber.supportedLocales
        let availability = LanguageAvailability()
        let homeLanguage = Locale.Language(identifier: home)
        let homeCode = EngineMapping.languageCode(Locale(identifier: home))
        var translation: [String: Directions] = [:]
        for language in await availability.supportedLanguages {
            guard let code = language.languageCode?.identifier, code != homeCode, translation[code] == nil else { continue }
            translation[code] = (toHome: await availability.status(from: language, to: homeLanguage),
                                 fromHome: await availability.status(from: homeLanguage, to: language))
        }
        let voices = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        return assemble(home: home, speechLocales: speech, dictationLocales: dictation, translation: translation,
                        voices: voices)
    }
}

/// `missing(pair)`: what must be downloaded before `start` can run the pair (R3). Unsupported items are left
/// out (they cannot be downloaded; `capabilities()` already does not offer them).
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
    static func gather(_ pair: PairMsg) async -> [MissingMsg] {
        var speech: [(language: String, status: AssetInventory.Status?)] = []
        for language in [pair.other, pair.home] {
            let recognizer = await LiveTranscriber.resolve(language)
            speech.append((language, await recognizer?.assetStatus))
        }
        let availability = LanguageAvailability()
        let other = Locale.Language(identifier: pair.other), home = Locale.Language(identifier: pair.home)
        let translation = [
            (from: pair.other, to: pair.home, status: await availability.status(from: other, to: home)),
            (from: pair.home, to: pair.other, status: await availability.status(from: home, to: other)),
        ]
        return assemble(pair: pair, speech: speech, translation: translation,
                        hasVoice: EngineMapping.bestVoice(pair.home) != nil)
    }
}

/// The last capabilities, gathered in the background at launch and after each download, so the synchronous
/// pigeon call (on the main thread) usually returns at once. A call that finds no value waits a bounded time
/// for the one gather in flight (it is not restarted); on timeout the caller throws `notReady` and the gather
/// still fills the cache for the next call. The first framework query in a fresh process can be slow (more than
/// 20 s once on the Mac host, cold daemons), and the main thread must not wait that long.
final class CapabilitiesCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (home: String, value: CapabilitiesMsg)?
    private var inFlight: (home: String, done: DispatchGroup)?
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

    /// The cached value for `home`, else waits up to `timeout` for the gather in flight; nil on timeout
    func get(home: String, timeout: TimeInterval) -> CapabilitiesMsg? {
        if let hit = lock.withLock({ cached }), hit.home == home { return hit.value }
        let done = startGather(home: home)
        guard done.wait(timeout: .now() + timeout) == .success else {
            Diag.log("capabilities: not ready after \(timeout) s, still gathering")
            return nil
        }
        return lock.withLock { cached?.home == home ? cached?.value : nil }
    }

    private func startGather(home: String) -> DispatchGroup {
        lock.lock()
        defer { lock.unlock() }
        if let running = inFlight, running.home == home { return running.done }
        let done = DispatchGroup()
        done.enter()
        inFlight = (home, done)
        let started = epoch
        Task.detached { [self] in
            let value = await gather(home)
            lock.withLock {
                guard epoch == started else { return }
                cached = (home, value)
                if inFlight?.done === done { inFlight = nil }
            }
            done.leave()
        }
        return done
    }
}

/// Runs async framework queries for a synchronous pigeon method (`capabilities`, `missing` are sync in the
/// contract). The work runs detached and must not need the main actor, or it waits for the timeout.
enum Blocking {
    private final class Box<T>: @unchecked Sendable { var value: T? }

    static func run<T>(timeout: TimeInterval, _ work: @escaping @Sendable () async -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            Diag.log("blocking: gave up after \(timeout) s")
            return nil
        }
        return box.value
    }
}
