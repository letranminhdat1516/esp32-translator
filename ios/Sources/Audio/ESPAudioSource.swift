import AVFAudio
import os

// The Swift app's board-audio path (ConversationEngine decodes the BLE ADPCM itself). BufferConverter, MicSource
// and SilencePlayer are shared with the multi-language engine: Engine/AudioSources.swift.

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
