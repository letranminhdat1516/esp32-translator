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

/// Energy voice-activity gate with an adaptive noise floor, a pre-roll and a hangover.
/// Mirrors the board's VAD so the recognizer only works while someone is actually speaking.
final class VoiceGate {
    private let preroll: TimeInterval = 0.3
    private let hangover: TimeInterval = 0.8
    private let marginDB: Float = 10
    private let minDB: Float = -58
    private let floorRisePerSecond: Float = 0.5

    private var floorDB: Float = -60
    private var buffered: [AVAudioPCMBuffer] = []
    private var bufferedSeconds: TimeInterval = 0
    private var speaking = false
    private var silentFor: TimeInterval = 0

    enum Output { case none, audio([AVAudioPCMBuffer]), ended }

    func process(_ buffer: AVAudioPCMBuffer) -> Output {
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let db = Self.levelDB(buffer)
        if db < floorDB { floorDB = db } else { floorDB += floorRisePerSecond * Float(seconds) }
        let voiced = db > floorDB + marginDB && db > minDB

        if speaking {
            if voiced {
                silentFor = 0
            } else {
                silentFor += seconds
                if silentFor > hangover {
                    speaking = false
                    return .ended
                }
            }
            return .audio([buffer])
        }

        buffered.append(buffer)
        bufferedSeconds += seconds
        while bufferedSeconds > preroll, let first = buffered.first {
            bufferedSeconds -= Double(first.frameLength) / first.format.sampleRate
            buffered.removeFirst()
        }
        guard voiced else { return .none }
        speaking = true
        silentFor = 0
        defer { buffered.removeAll(); bufferedSeconds = 0 }
        return .audio(buffered)
    }

    private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -100 }
        var sum: Float = 0
        if let p = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += p[i] * p[i] }
        } else if let p = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v }
        }
        return 10 * log10(sum / Float(n) + 1e-10)
    }
}

/// AirPods mic (or the iPhone mic without earbuds), with echo cancellation of the spoken output.
/// Only speech reaches the recognizer; `onSpeechEnd` fires when the speaker pauses.
final class MicSource {
    private let engine = AVAudioEngine()
    private let converter: BufferConverter
    private let gate = VoiceGate()
    private let sink: (AVAudioPCMBuffer) -> Void
    private let onSpeechEnd: () -> Void

    init(target: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void, onSpeechEnd: @escaping () -> Void) {
        converter = BufferConverter(target: target)
        self.sink = sink
        self.onSpeechEnd = onSpeechEnd
    }

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        Diag.log("mic: input format \(format)")
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [converter, gate, sink, onSpeechEnd] buffer, _ in
            Diag.count("mic.buffers")
            switch gate.process(buffer) {
            case .none:
                break
            case .audio(let buffers):
                for b in buffers {
                    if let converted = converter.convert(b) { sink(converted) }
                }
            case .ended:
                onSpeechEnd()
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
