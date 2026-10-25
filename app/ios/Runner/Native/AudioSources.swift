import AVFAudio
import os

// Copied from ios/Sources/Audio/AudioSources.swift without ESPAudioSource (Dart decodes the board audio and
// feeds PCM through feedTheirAudio). The Swift app keeps its own copy until P8.

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
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

/// AirPods mic (or the iPhone mic without earbuds), with echo cancellation of the spoken output.
/// Only the wearer's speech reaches the recognizer (see `VoiceGate`); `onSpeechStart` fires when the gate opens
/// and `onSpeechEnd` when they pause (both on the audio thread).
final class MicSource {
    private let engine = AVAudioEngine()
    private let converter: BufferConverter
    private let gate: VoiceGate
    private let sink: (AVAudioPCMBuffer) -> Void
    private let onSpeechStart: () -> Void
    private let onSpeechEnd: () -> Void
    private var gateOpen = false

    init(target: AVAudioFormat, gate: VoiceGate = VoiceGate(),
         sink: @escaping (AVAudioPCMBuffer) -> Void, onSpeechStart: @escaping () -> Void = {},
         onSpeechEnd: @escaping () -> Void) {
        converter = BufferConverter(target: target)
        self.gate = gate
        self.sink = sink
        self.onSpeechStart = onSpeechStart
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
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [gate] _ in
                gate.resetWearerLevel()
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
        for event in gate.process(converted) {
            switch event {
            case .audio(let b):
                if !gateOpen {
                    gateOpen = true
                    onSpeechStart()
                }
                sink(b)
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
            onSpeechEnd()
        }
    }
}

/// Plays silence while no conversation is going on, so iOS keeps the app running in the background (the BLE
/// keepalive timer, board audio, the idle timeout). Mixable output only: no mic, no ducking, so other apps'
/// audio is untouched and the AirPods stay in high-quality A2DP.
final class SilencePlayer {
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
