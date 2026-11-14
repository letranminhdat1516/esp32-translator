import AVFAudio
import os

// Audio sources shared by AppleVoiceEngine and the Swift app's ConversationEngine. The engine gets the board
// audio as PCM (feedTheirAudio); ConversationEngine decodes it with Audio/ESPAudioSource.swift.

/// Converts buffers to the format SpeechAnalyzer wants (usually 16 kHz mono Int16)
final class BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let input = OneBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard let next = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    /// The input of one `convert` call, handed out once. The converter calls its input block synchronously inside
    /// `convert(to:error:withInputFrom:)`, so the block never runs concurrently with the caller.
    private final class OneBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

/// `VoiceGate.resetWearerLevel` for notification observers (any thread): the one VoiceGate call that is
/// thread safe (it only sets a locked flag the audio thread reads)
private struct WearerLevelReset: @unchecked Sendable {
    let gate: VoiceGate
    func callAsFunction() { gate.resetWearerLevel() }
}

/// AirPods mic (or the iPhone mic without earbuds), with echo cancellation of the spoken output.
/// Only the wearer's speech reaches the recognizer (see `VoiceGate`); `onSpeechStart` fires when the gate opens,
/// `onFinalize` when they pause (`VoiceGate.Config.finalizeAfter`, possibly more than once per opening, always
/// before the close) and `onSpeechEnd` when the gate closes (all on the audio thread).
final class MicSource {
    /// Sees every converted mic buffer before the gate (Track C: `MicPCMTap` fills the "mine" clip ring, memory
    /// only). Set once at launch; called on the audio thread.
    nonisolated(unsafe) static var tap: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let converter: BufferConverter
    private let gate: VoiceGate
    private let sink: (AVAudioPCMBuffer) -> Void
    private let onSpeechStart: () -> Void
    private let onFinalize: () -> Void
    private let onSpeechEnd: () -> Void
    private var gateOpen = false
    /// Audio was passed since the last `onFinalize`
    private var unfinalized = false

    init(target: AVAudioFormat, gate: VoiceGate = VoiceGate(),
         sink: @escaping (AVAudioPCMBuffer) -> Void, onSpeechStart: @escaping () -> Void = {},
         onFinalize: @escaping () -> Void = {}, onSpeechEnd: @escaping () -> Void) {
        converter = BufferConverter(target: target)
        self.gate = gate
        self.sink = sink
        self.onSpeechStart = onSpeechStart
        self.onFinalize = onFinalize
        self.onSpeechEnd = onSpeechEnd
    }

    private var observers: [NSObjectProtocol] = []

    func start() throws {
        // A different mic (AirPods ↔ iPhone) or a new engine configuration changes the wearer's level
        let center = NotificationCenter.default
        var names: [Notification.Name] = [.AVAudioEngineConfigurationChange]
        #if os(iOS)
        names.append(AVAudioSession.routeChangeNotification)
        #endif
        let resetWearerLevel = WearerLevelReset(gate: gate)
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                resetWearerLevel()
            })
        }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        Diag.log("mic: input format \(format)")
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            Diag.count("mic.buffers")
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Converts one mic buffer to the recognizer format, gates it and forwards it (the tap calls this, and so
    /// does ios/Tools/vi-harness, which runs this exact path on recorded files)
    func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        Self.tap?(converted)
        for event in gate.process(converted) {
            switch event {
            case .audio(let b):
                if !gateOpen {
                    gateOpen = true
                    onSpeechStart()
                }
                unfinalized = true
                sink(b)
            case .finalize:
                unfinalized = false
                onFinalize()
            case .ended:
                gateOpen = false
                onSpeechEnd()
            }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if gateOpen {
            gateOpen = false
            if unfinalized { onFinalize() }
            onSpeechEnd()
        }
        unfinalized = false
    }
}

/// Plays silence while no conversation is going on, so iOS keeps the app running in the background (the BLE
/// keepalive timer, board audio, the idle timeout). Mixable output only: no mic, no ducking, so other apps'
/// audio is untouched and the AirPods stay in high-quality A2DP.
///
/// `@unchecked Sendable`: its configuration-change observer runs on the notification's thread; it reads `wanted`
/// (locked) and restarts the AVAudioEngine, which may be started and stopped from any thread.
final class SilencePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()

    init() {
        let silence = AVAudioSourceNode { _, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    }

    private let wanted = OSAllocatedUnfairLock(initialState: false)
    private var observer: NSObjectProtocol?

    func start() throws {
        wanted.withLock { $0 = true }
        // A route change (AirPods in or out) stops the engine: start it again while silence is wanted
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: nil) { [weak self] _ in
                guard let self, self.wanted.withLock({ $0 }), !self.engine.isRunning else { return }
                do {
                    self.engine.prepare()
                    try self.engine.start()
                    Diag.log("idle: silence restarted after a configuration change")
                } catch {
                    Diag.log("idle: silence restart failed: \(error.localizedDescription)")
                }
            }
        }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        wanted.withLock { $0 = false }
        engine.stop()
    }
}
