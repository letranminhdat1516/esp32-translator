// The VoiceGate shipped before the own-voice gate (verbatim copy of the old
// ios/Sources/Audio/AudioSources.swift), kept only as the baseline for the harness.
import AVFAudio


/// Energy voice-activity gate with an adaptive noise floor, a pre-roll and a hangover.
/// Mirrors the board's VAD so the recognizer only works while someone is actually speaking.
final class LegacyVoiceGate {
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

