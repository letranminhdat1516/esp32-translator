import AVFAudio

/// Chuyển buffer sang định dạng mà SpeechAnalyzer muốn (thường 16 kHz mono Int16)
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

/// Âm thanh từ mic board ESP32 (gói BLE ADPCM, 16 kHz mono)
final class ESPAudioSource: @unchecked Sendable {
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: true)!
    private var decoder = ADPCMDecoder()
    private let converter: BufferConverter
    private let sink: (AVAudioPCMBuffer) -> Void

    init(target: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void) {
        converter = BufferConverter(target: target)
        self.sink = sink
    }

    /// Gọi trên hàng đợi BLE
    func handle(packet: Data) {
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

/// Mic AirPods (hoặc mic iPhone nếu không đeo tai nghe), có khử tiếng vọng của giọng đọc
final class MicSource {
    private let engine = AVAudioEngine()
    private let converter: BufferConverter
    private let sink: (AVAudioPCMBuffer) -> Void

    init(target: AVAudioFormat, sink: @escaping (AVAudioPCMBuffer) -> Void) {
        converter = BufferConverter(target: target)
        self.sink = sink
    }

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [converter, sink] buffer, _ in
            if let converted = converter.convert(buffer) { sink(converted) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
