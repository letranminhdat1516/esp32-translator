import AVFAudio
import Foundation

/// Typed engine failures. Pigeon sends a thrown `PigeonError` to Dart as a `PlatformException` with the same
/// code, and the Dart side maps codes named after `EngineError` (controller ruling, Phase 0).
/// `PigeonError` is used rather than `FlutterError` because `FlutterError` is not a Swift `Error`; both
/// travel as the same (code, message, details) triple.
enum EngineErrors {
    static func translateFailed(_ message: String?) -> PigeonError { make("translateFailed", message) }
    static func notReady(_ message: String?) -> PigeonError { make("notReady", message) }
    static func downloadFailed(_ message: String?) -> PigeonError { make("downloadFailed", message) }

    private static func make(_ code: String, _ message: String?) -> PigeonError {
        PigeonError(code: code, message: message, details: nil)
    }
}

/// Builds the pigeon messages from what the iOS frameworks report
enum EngineMapping {
    /// A home-side (mic) result. Times are epoch milliseconds: the result ends when it arrives and starts the
    /// length of its audio earlier (the gate drops silence, so the recognizer's own audio clock is not wall time).
    static func mine(_ event: TranscriptEvent, now: Date) -> MineMsg {
        let end = Int64((now.timeIntervalSince1970 * 1000).rounded())
        switch event {
        case .partial(let text, let audio):
            return MineMsg(kind: .partial, text: text, startMs: end - millis(audio), endMs: end)
        case .final(let text, _, let audio):
            return MineMsg(kind: .finalText, text: text, startMs: end - millis(audio), endMs: end)
        }
    }

    /// An other-side (board) result: finals only, with the generation of the pair that produced it
    static func theirs(_ event: TranscriptEvent, generation: Int64) -> TheirsMsg? {
        guard case .final(let text, let confidence, _) = event, !text.isEmpty else { return nil }
        return TheirsMsg(text: text, confidence: confidence, generation: generation)
    }

    private static func millis(_ seconds: TimeInterval) -> Int64 {
        Int64((max(0, seconds) * 1000).rounded())
    }

    /// Headset when the mic is in earbuds or a headset, else the phone mic
    static func route(inputs: [AVAudioSession.Port]) -> AudioRoute {
        let headset: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .headsetMic, .usbAudio, .carAudio]
        return inputs.contains(where: headset.contains) ? .headset : .phoneMic
    }

    /// A device came or went; category changes are the engine's own doing and not reported
    static func reportsRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep, .noSuitableRouteForCategory:
            true
        default:
            false
        }
    }

    /// 16-bit little-endian mono PCM as an Int16 buffer; nil for empty or odd-length input
    static func pcm16Buffer(_ bytes: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        let count = bytes.count / 2
        guard count > 0, bytes.count % 2 == 0, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let dst = buffer.int16ChannelData?[0]
        else { return nil }
        bytes.withUnsafeBytes { raw in
            for i in 0..<count {
                dst[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }

    /// The language code of a locale ("en_US" → "en"); the identifier itself when it has none
    static func languageCode(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }
}

/// One `VoiceEngineEvents` call
enum EngineEvent: @unchecked Sendable {
    case mine(MineMsg)
    case theirs(TheirsMsg)
    case gate(Bool)
    case ttsStart(Int64)
    case ttsEnd(Int64)
    case audioSession(AudioSessionMsg)
    case download(DownloadMsg)
}

/// Events from any thread (audio tap, recognizer tasks, main), delivered to Dart one at a time, in the order
/// they were sent, on the main thread
final class EventQueue: Sendable {
    private let continuation: AsyncStream<EngineEvent>.Continuation

    init(deliver: @escaping @MainActor (EngineEvent) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task { @MainActor in
            for await event in stream { await deliver(event) }
        }
    }

    deinit { continuation.finish() }

    func send(_ event: EngineEvent) {
        continuation.yield(event)
    }

    /// Sends to the generated Flutter API. A failed send (no Dart listener yet) is logged and dropped.
    static func flutter(_ events: VoiceEngineEventsProtocol) -> EventQueue {
        EventQueue { event in
            do {
                switch event {
                case .mine(let m): try await events.onMine(msg: m)
                case .theirs(let m): try await events.onTheirs(msg: m)
                case .gate(let open): try await events.onGate(open: open)
                case .ttsStart(let id): try await events.onTtsStart(id: id)
                case .ttsEnd(let id): try await events.onTtsEnd(id: id)
                case .audioSession(let m): try await events.onAudioSession(msg: m)
                case .download(let m): try await events.onDownload(msg: m)
                }
            } catch {
                Diag.log("events: \(event) not delivered: \(error)")
            }
        }
    }
}
