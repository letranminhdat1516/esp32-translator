import AVFAudio
import os

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

/// Audio from the ESP32 board mics (BLE ADPCM packets, 16 kHz mono).
/// The board only streams while it hears speech, so a pause in packets means the phrase has ended.
final class ESPAudioSource: @unchecked Sendable {
    private let lastPacket = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// True once, the first time it is asked after packets have stopped for `gap`
    func streamEnded(after gap: TimeInterval) -> Bool {
        lastPacket.withLock { last in
            guard let l = last, Date().timeIntervalSince(l) > gap else { return false }
            last = nil
            return true
        }
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: true)!
    private var decoder = ADPCMDecoder()
    private let converter: BufferConverter
    private let sink: (AVAudioPCMBuffer) -> Void

    init(target: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void) {
        converter = BufferConverter(target: target)
        self.sink = sink
    }

    /// Called on the BLE queue
    func handle(packet: Data) {
        Diag.count("esp.packets")
        lastPacket.withLock { $0 = Date() }
        let samples = decoder.decode(packet)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if let converted = converter.convert(buffer) { sink(converted) }
    }

    func reset() { decoder.reset() }
}

/// AirPods mic (or the iPhone mic without earbuds), with echo cancellation of the spoken output.
/// Only the wearer's speech reaches the recognizer (see `VoiceGate`); `onSpeechEnd` fires when they pause.
final class MicSource {
    private let engine = AVAudioEngine()
    private let converter: BufferConverter
    private let gate: VoiceGate
    private let sink: (AVAudioPCMBuffer) -> Void
    private let onSpeechEnd: () -> Void

    init(target: AVAudioFormat, gate: VoiceGate = VoiceGate(),
         sink: @escaping (AVAudioPCMBuffer) -> Void, onSpeechEnd: @escaping () -> Void) {
        converter = BufferConverter(target: target)
        self.gate = gate
        self.sink = sink
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
            case .audio(let b): sink(b)
            case .ended: onSpeechEnd()
            }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
