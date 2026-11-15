import AVFAudio
import os

/// `CrossTalkArbiter` applied to the engine's two audio paths: board PCM (main actor, one BLE packet at a time)
/// and my mic's gated audio (the audio thread). Each 20 ms frame is measured and passed on unchanged, or replaced
/// with digital silence of the same length while the other side holds the floor: the recognizers keep their
/// timing (their recognizer is never finalized and needs continuous audio, see `BoardSilencePadder`; mine is
/// finalized by the gate, and silence there just transcribes as nothing).
///
/// Both sides are measured after their own gate (the board's near-field VAD, `VoiceGate`): a side that streams
/// nothing has nothing to suppress, and each opening starts with background, which gives the floor.
///
/// Thread safe (one lock around the arbiter). Logs owner changes at most once per `logInterval`; the silenced
/// frames are counted in the `crosstalk.*Silenced` diagnostics counters.
final class CrossTalkGuard: @unchecked Sendable {
    typealias Side = CrossTalkArbiter.Side

    /// Analysis frame for my mic's buffers (board packets are one frame each, 20 ms or less)
    static let frame: TimeInterval = 0.02
    static let logInterval: TimeInterval = 1

    private struct State {
        var arbiter: CrossTalkArbiter
        var lastLog: TimeInterval = -.infinity
        var unloggedChanges = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> TimeInterval

    init(config: CrossTalkArbiter.Config = .init(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        state = OSAllocatedUnfairLock(initialState: State(arbiter: CrossTalkArbiter(config: config)))
        self.now = now
    }

    /// One board packet: the same samples, or as many zeros while my side holds the floor
    func theirs(_ pcm: [Int16]) -> [Int16] {
        guard !pcm.isEmpty else { return pcm }
        var energy: Float = 0
        for s in pcm {
            let x = Float(s) / 32768
            energy += x * x
        }
        let db = 10 * log10(energy / Float(pcm.count) + 1e-10)
        guard decide(.theirs, levels: [db]).contains(true) else { return pcm }
        Diag.count("crosstalk.theirSilenced")
        return [Int16](repeating: 0, count: pcm.count)
    }

    /// My mic's gated audio: the same buffer, or a copy with the frames the board side holds silenced
    func mine(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let samples = VoiceGate.floats(buffer)
        let length = max(1, Int(Self.frame * buffer.format.sampleRate))
        guard !samples.isEmpty else { return buffer }
        let starts = Array(stride(from: 0, to: samples.count, by: length))
        let levels = starts.map { VoiceGate.levelDB(Array(samples[$0..<min($0 + length, samples.count)])) }
        let silenced = decide(.mine, levels: levels)
        guard silenced.contains(true) else { return buffer }
        Diag.count("crosstalk.mineSilenced", silenced.filter { $0 }.count)
        var out = samples
        for (start, silence) in zip(starts, silenced) where silence {
            for i in start..<min(start + length, out.count) { out[i] = 0 }
        }
        return Self.copy(out, like: buffer)
    }

    /// Forgets everything (engine torn down)
    func reset() {
        state.withLock { $0.arbiter.reset() }
    }

    /// Forgets my side's levels (a different mic: AirPods ↔ iPhone)
    func reset(_ side: Side) {
        state.withLock { $0.arbiter.reset(side) }
    }

    /// Runs the frames through the arbiter (all at the current time) and logs an owner change, rate-limited
    private func decide(_ side: Side, levels: [Float]) -> [Bool] {
        let t = now()
        let (suppress, line) = state.withLock { s -> ([Bool], String?) in
            var changed = false
            let out = levels.map { db -> Bool in
                let d = s.arbiter.observe(side, levelDB: db, at: t)
                changed = changed || d.changed
                return d.suppress
            }
            guard changed else { return (out, nil) }
            guard t - s.lastLog >= Self.logInterval else {
                s.unloggedChanges += 1
                return (out, nil)
            }
            func describe(_ side: Side) -> String {
                let v = s.arbiter.state(side, at: t)
                guard v.snrDB.isFinite else { return "\(side.rawValue) silent" }
                return String(format: "%@ %.0f dB over its floor, score %.0f", side.rawValue, v.snrDB, v.scoreDB)
            }
            let skipped = s.unloggedChanges > 0 ? ", \(s.unloggedChanges) changes not logged" : ""
            let line = "crosstalk: floor \(s.arbiter.owner?.rawValue ?? "open") (\(describe(.mine)); \(describe(.theirs)))\(skipped)"
            s.lastLog = t
            s.unloggedChanges = 0
            return (out, line)
        }
        if let line { Diag.log(line) }
        return suppress
    }

    /// `samples` (first channel) in a new buffer of `buffer`'s format; other channels get the same samples
    private static func copy(_ samples: [Float], like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return buffer
        }
        out.frameLength = AVAudioFrameCount(samples.count)
        let channels = format.isInterleaved ? 1 : Int(format.channelCount)
        if let p = out.floatChannelData, !format.isInterleaved || format.channelCount == 1 {
            for c in 0..<channels { p[c].update(from: samples, count: samples.count) }
        } else if let p = out.int16ChannelData, !format.isInterleaved || format.channelCount == 1 {
            for c in 0..<channels {
                for i in 0..<samples.count { p[c][i] = Int16(max(-32768, min(32767, (samples[i] * 32768).rounded()))) }
            }
        } else {
            // A format this does not write: the whole buffer goes as silence rather than as cross-talk
            return EngineMapping.silence(seconds: Double(samples.count) / format.sampleRate, format: format) ?? buffer
        }
        return out
    }
}
