import AVFAudio
import Foundation

/// Typed engine failures (Core `EngineError`). The reason is logged; the caller gets only the code, as the
/// `VoiceEngine` contract says.
enum EngineErrors {
    static func translateFailed(_ message: String) -> EngineError { fail(.translateFailed, message) }
    static func notReady(_ message: String) -> EngineError { fail(.notReady, message) }
    static func downloadFailed(_ message: String) -> EngineError { fail(.downloadFailed, message) }

    private static func fail(_ error: EngineError, _ message: String) -> EngineError {
        Diag.log("engine: \(error.rawValue): \(message)")
        return error
    }
}

/// A download that did not complete, with its reason; `Downloads` reports the reason in `DownloadMsg.error` and
/// throws `EngineError.downloadFailed`.
struct DownloadFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Builds the engine messages from what the iOS frameworks report
enum EngineMapping {
    /// A home-side (mic) result. Times are epoch milliseconds: the result ends when it arrives and starts the
    /// length of its audio earlier (the gate drops silence, so the recognizer's own audio clock is not wall time).
    static func mine(_ event: TranscriptEvent, now: Date) -> MineMsg {
        let end = Int((now.timeIntervalSince1970 * 1000).rounded())
        switch event {
        case .partial(let text, let audio):
            return MineMsg(kind: .partial, text: text, startMs: end - millis(audio), endMs: end)
        case .final(let text, _, let audio):
            return MineMsg(kind: .finalText, text: text, startMs: end - millis(audio), endMs: end)
        }
    }

    /// An other-side (board) result: finals only, with the generation of the pair that produced it
    static func theirs(_ event: TranscriptEvent, generation: Int) -> TheirsMsg? {
        guard case .final(let text, let confidence, _) = event, !text.isEmpty else { return nil }
        return TheirsMsg(text: text, confidence: confidence, generation: generation)
    }

    private static func millis(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1000).rounded())
    }

    /// 16-bit mono PCM samples as an Int16 buffer; nil for empty input or a non-positive rate
    static func pcm16Buffer(_ samples: [Int16], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.int16ChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// `seconds` of digital silence in `format` (any sample format, every channel zeroed)
    static func silence(seconds: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded())
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        return buffer
    }

    /// The highest-quality installed TTS voice for a language code or locale identifier, or nil
    static func bestVoice(_ language: String) -> AVSpeechSynthesisVoice? {
        let code = languageCode(Locale(identifier: language))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { languageCode(Locale(identifier: $0.language)) == code }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// The language code of a locale ("en_US" → "en"); the identifier itself when it has none
    static func languageCode(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }
}

/// Pack code ↔ the locales the Apple frameworks use (R1, R16). The engine contract (`PairMsg`, capabilities,
/// `MissingMsg`) speaks pack codes ("en", "zh-Hans"); the frameworks get:
/// - the recognizer: the pack's `appleLocale` ("zh-CN"), the code itself when it is empty or there is no pack;
/// - Translation: `Locale.Language(identifier: code)` ("zh-Hans", distinct from "zh-Hant").
/// What the device reports (speech locales, translation languages) maps back to the pack with the same language
/// and script; with no such pack, to the bare language code (plus the script when it is not that language's
/// default one, so "zh_TW" is "zh-Hant", never "zh"/"zh-Hans").
struct EngineLocales: Sendable {
    private struct Key: Hashable {
        let language: String
        let script: String?
    }

    private let appleLocales: [String: String]
    private let codes: [Key: String]

    init(packs: [LanguagePack] = []) {
        var apple: [String: String] = [:], codes: [Key: String] = [:]
        for pack in packs {
            if !pack.appleLocale.isEmpty { apple[pack.code] = pack.appleLocale }
            if let key = Self.key(Locale.Language(identifier: pack.code)), codes[key] == nil { codes[key] = pack.code }
        }
        appleLocales = apple
        self.codes = codes
    }

    /// The locale to ask the recognizers for
    func speechLocale(_ code: String) -> Locale {
        Locale(identifier: appleLocales[code] ?? code)
    }

    /// The language to give Translation
    func translationLanguage(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code)
    }

    /// The pack code of a device-reported locale
    func code(for locale: Locale) -> String { code(for: locale.language) }

    /// The pack code of a device-reported language
    func code(for language: Locale.Language) -> String {
        guard let key = Self.key(language) else { return language.minimalIdentifier }
        if let code = codes[key] { return code }
        let defaultScript = Self.key(Locale.Language(identifier: key.language))?.script
        guard let script = key.script, script != defaultScript else { return key.language }
        return "\(key.language)-\(script)"
    }

    /// Language and (likely) script: "zh_CN", "zh" and "zh-Hans" are one key, "zh_TW" and "zh-Hant" another
    private static func key(_ language: Locale.Language) -> Key? {
        let full = Locale.Language(identifier: language.maximalIdentifier)
        guard let code = full.languageCode?.identifier ?? language.languageCode?.identifier else { return nil }
        return Key(language: code, script: full.script?.identifier ?? language.script?.identifier)
    }
}

/// One engine event, as the `VoiceEngine` streams carry them
enum EngineEvent: Sendable, Equatable {
    case mine(MineMsg)
    case theirs(TheirsMsg)
    case gate(Bool)
    case ttsStart(Int)
    case ttsEnd(Int)
    case audioSession(AudioSessionMsg)
    case download(DownloadMsg)
}

/// The engine's event streams (Core `Broadcast`, one per `VoiceEngine` event property). `send` is thread safe
/// (audio tap, recognizer tasks, main actor); each stream keeps the order of its sends.
final class EngineEventSink: Sendable {
    let mine = Broadcast<MineMsg>()
    let theirs = Broadcast<TheirsMsg>()
    let gate = Broadcast<Bool>()
    let ttsStart = Broadcast<Int>()
    let ttsEnd = Broadcast<Int>()
    let audioSession = Broadcast<AudioSessionMsg>()
    let download = Broadcast<DownloadMsg>()

    func send(_ event: EngineEvent) {
        switch event {
        case .mine(let m): mine.send(m)
        case .theirs(let m): theirs.send(m)
        case .gate(let open): gate.send(open)
        case .ttsStart(let id): ttsStart.send(id)
        case .ttsEnd(let id): ttsEnd.send(id)
        case .audioSession(let m): audioSession.send(m)
        case .download(let m): download.send(m)
        }
    }
}
