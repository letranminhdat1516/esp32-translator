import Accelerate
import AVFAudio

/// Own-voice gate for the AirPods mic: passes audio to the Vietnamese recognizer only while the wearer speaks.
///
/// Speech from people nearby, heard just before or after your own words, was the largest source of
/// Vietnamese recognition errors: the recognizer transcribed it and it was translated as if you had said it.
/// The wearer's mouth is a few centimetres from the AirPods mics, so their voice arrives much louder than
/// anyone else's. A 20 ms frame counts as the wearer only if it is well above the background level, voiced
/// (periodic at a speech pitch) and near the wearer's own learned level. The gate keeps 300 ms of pre-roll
/// so the first syllable is not cut, and closes 0.8 s after the voice stops.
///
/// The background level is a low percentile of the frame levels over the last few seconds. It follows
/// sustained café babble within seconds (the old floor rose 0.5 dB/s and never caught up, so the gate
/// stayed open), and it stays low while you talk because the gaps between syllables keep it down.
///
/// Measured with ios/Tools/vi-harness on synthetic Vietnamese speech in café babble (see the README).
/// Cost: one level, a percentile of 150 values and, only for frames above the background, one short
/// autocorrelation per 20 ms frame: about 0.05 % of one Mac core, mic format conversion included.
final class VoiceGate {
    struct Config {
        /// Audio kept from before the gate opens, so the first syllable is not cut
        var preroll: TimeInterval = 0.3
        /// The gate closes after this much non-speech (1.2 s measured no better and adds latency)
        var hangover: TimeInterval = 0.8
        /// Analysis frame
        var frame: TimeInterval = 0.02
        /// Background level: this percentile of frame levels over the last `floorWindow` seconds
        var floorWindow: TimeInterval = 3
        /// 5 %: the gaps between syllables keep it at the background even during a long sentence in babble
        /// (10 % rose into the voice and cut 7 s of a 30 s monologue at 3 dB SNR)
        var floorPercentile = 0.05
        /// A frame counts as the wearer's voice only this far above the background…
        var openMarginDB: Float = 8
        /// …and keeps the gate open while this far above it and voiced
        var holdMarginDB: Float = 6
        /// Never open below this absolute level (quiet room hiss)
        var minDB: Float = -58
        /// The wearer's own level, tracked as the 90th percentile of their voiced frames. A frame must be
        /// within `nearMarginDB` of it to open or hold the gate: bystanders and the person you talk to are
        /// 15–25 dB quieter than the wearer at the AirPods mics. The check starts after `userMinSpeech`
        /// seconds of the wearer's speech, and the level sinks by `userDecayPerSecond` while the gate is
        /// closed, so a softer voice later is never locked out for long (12 dB softer: about 40 s).
        var nearMarginDB: Float = 10
        var userMinSpeech: TimeInterval = 1
        var userDecayPerSecond: Float = 0.05
        /// Normalized autocorrelation peak at the pitch period (0…1) for a frame to count as voiced
        var voicing: Float = 0.45
        /// Opening needs `onsetFrames` loud, voiced frames within `onsetWindow` (rejects clicks and lone babble peaks)
        var onsetWindow: TimeInterval = 0.2
        var onsetFrames = 4
        /// Pitch search range
        var minPitchHz: Double = 80
        var maxPitchHz: Double = 400
    }

    enum Event {
        /// Audio to pass to the recognizer, in the input buffer's format
        case audio(AVAudioPCMBuffer)
        /// The wearer stopped speaking: finalize
        case ended
    }

    let config: Config

    private var sampleRate: Double = 0
    private var frameLength = 0
    private var minLag = 0
    private var maxLag = 0

    /// Samples not yet analyzed (less than one frame)
    private var partial: [Float] = []
    /// Recent audio while closed: pre-roll plus the onset window
    private var history: [Float] = []
    private var historyCapacity = 0
    /// Last few frames for the pitch analysis window
    private var analysis: [Float] = []
    private var analysisLength = 0

    /// Ring of recent frame levels for the background estimate
    private var levels: [Float] = []
    private var levelIndex = 0
    private var levelCount = 0
    private var sortScratch: [Float] = []
    private(set) var floorDB: Float = -100

    /// The wearer's level (90th-percentile tracker) and how many of their frames it has seen
    private(set) var userLevelDB: Float?
    private var userFrames = 0

    /// Loud and voiced flags for the frames in the onset window (oldest first)
    private var onset: [Bool] = []
    private var speaking = false
    private var silentFor: TimeInterval = 0

    /// Statistics for diagnostics and the harness
    private(set) var framesAnalyzed = 0
    private(set) var pitchAnalyses = 0

    init(config: Config = Config()) {
        self.config = config
    }

    var isOpen: Bool { speaking }

    /// Splits the buffer into frames and returns what to send to the recognizer, in order
    func process(_ buffer: AVAudioPCMBuffer) -> [Event] {
        let format = buffer.format
        if format.sampleRate != sampleRate { configure(sampleRate: format.sampleRate) }
        let samples = Self.floats(buffer)
        var events: [Event] = []
        var out: [Float] = []

        partial.append(contentsOf: samples)
        var start = 0
        while partial.count - start >= frameLength {
            let frame = Array(partial[start..<start + frameLength])
            start += frameLength
            step(frame, out: &out, events: &events, format: format)
        }
        partial.removeFirst(start)
        if !out.isEmpty, let b = Self.buffer(out, format: format) { events.append(.audio(b)) }
        return events
    }

    // MARK: Per frame

    private func step(_ frame: [Float], out: inout [Float], events: inout [Event], format: AVAudioFormat) {
        framesAnalyzed += 1
        analysis.append(contentsOf: frame)
        if analysis.count > analysisLength { analysis.removeFirst(analysis.count - analysisLength) }

        let db = Self.levelDB(frame)
        pushLevel(db)
        let floor = floorDB
        let learned = Double(userFrames) * config.frame >= config.userMinSpeech
        let near = !learned || db >= userLevelDB! - config.nearMarginDB
        let loud = db > floor + config.openMarginDB && db > config.minDB && near
        let held = db > floor + config.holdMarginDB && db > config.minDB && near
        // The pitch analysis only runs when the level could open or hold the gate
        let voiced = (loud || (speaking && held)) ? isVoiced() : false

        if speaking {
            if loud && voiced { trackUserLevel(db) }
            if held && voiced {
                silentFor = 0
            } else {
                silentFor += config.frame
                if silentFor > config.hangover {
                    Diag.log(String(format: "gate: closed, background %.0f dB, voice %@", floorDB,
                                    userLevelDB.map { String(format: "%.0f dB", $0) } ?? "not learned"))
                    speaking = false
                    onset.removeAll()
                    history.removeAll()
                    if !out.isEmpty, let b = Self.buffer(out, format: format) { events.append(.audio(b)) }
                    out.removeAll()
                    events.append(.ended)
                    remember(frame)
                    return
                }
            }
            out.append(contentsOf: frame)
            return
        }

        remember(frame)
        if let level = userLevelDB { userLevelDB = level - config.userDecayPerSecond * Float(config.frame) }
        onset.append(loud && voiced)
        let window = max(1, Int((config.onsetWindow / config.frame).rounded()))
        if onset.count > window { onset.removeFirst(onset.count - window) }
        guard onset.filter({ $0 }).count >= config.onsetFrames, let first = onset.firstIndex(of: true) else { return }

        // Open: send the pre-roll before the first voiced frame, then everything since
        let framesSinceFirst = onset.count - first
        let keep = min(history.count, framesSinceFirst * frameLength + Int(config.preroll * sampleRate))
        out.append(contentsOf: history.suffix(keep))
        Diag.log(String(format: "gate: open at %.0f dB, background %.0f dB, voice %@", db, floor,
                        userLevelDB.map { String(format: "%.0f dB", $0) } ?? "not learned"))
        history.removeAll()
        onset.removeAll()
        speaking = true
        silentFor = 0
    }

    private func remember(_ frame: [Float]) {
        history.append(contentsOf: frame)
        if history.count > historyCapacity { history.removeFirst(history.count - historyCapacity) }
    }

    private func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int(config.frame * sampleRate))
        minLag = Int(sampleRate / config.maxPitchHz)
        maxLag = Int(sampleRate / config.minPitchHz)
        analysisLength = max(frameLength, 2 * maxLag + frameLength / 2)
        historyCapacity = Int((config.preroll + config.onsetWindow) * sampleRate) + frameLength
        userLevelDB = nil
        userFrames = 0
        let n = max(1, Int((config.floorWindow / config.frame).rounded()))
        levels = Array(repeating: 0, count: n)
        sortScratch = levels
        levelIndex = 0
        levelCount = 0
        partial.removeAll()
        history.removeAll()
        analysis.removeAll()
        onset.removeAll()
    }

    // MARK: Background level

    private func pushLevel(_ db: Float) {
        levels[levelIndex] = db
        levelIndex = (levelIndex + 1) % levels.count
        levelCount = min(levelCount + 1, levels.count)
        // Percentile of the filled part of the ring
        for i in 0..<levelCount { sortScratch[i] = levels[i] }
        sortScratch.withUnsafeMutableBufferPointer { p in
            vDSP_vsort(p.baseAddress!, vDSP_Length(levelCount), 1)
        }
        let k = min(levelCount - 1, Int(Double(levelCount - 1) * config.floorPercentile))
        floorDB = sortScratch[k]
    }

    // MARK: Wearer level

    /// Quantile tracker: up 0.45 dB per louder frame, down 0.05 dB per quieter one, so it settles where
    /// 10 % of the wearer's frames are louder (no sorting, no history)
    private func trackUserLevel(_ db: Float) {
        userFrames += 1
        guard let level = userLevelDB else {
            userLevelDB = db
            return
        }
        userLevelDB = level + (db > level ? 0.45 : -0.05)
    }

    // MARK: Voicing

    /// Peak of the normalized autocorrelation over the pitch range
    private func isVoiced() -> Bool {
        pitchAnalyses += 1
        let n = analysis.count
        guard n > maxLag + 32 else { return false }
        var x = analysis
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(n))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(n))
        var best: Float = 0
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            for lag in minLag...min(maxLag, n - 32) {
                let len = vDSP_Length(n - lag)
                var r: Float = 0, e0: Float = 0, e1: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &r, len)
                vDSP_svesq(base, 1, &e0, len)
                vDSP_svesq(base + lag, 1, &e1, len)
                let denom = (e0 * e1).squareRoot()
                if denom > 0 { best = max(best, r / denom) }
            }
        }
        return best >= config.voicing
    }

    // MARK: Buffers

    static func levelDB(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -100 }
        var ms: Float = 0
        vDSP_measqv(frame, 1, &ms, vDSP_Length(frame.count))
        return 10 * log10(ms + 1e-10)
    }

    static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return [] }
        if let p = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: p, count: n))
        }
        if let p = buffer.int16ChannelData?[0] {
            var out = [Float](repeating: 0, count: n)
            vDSP_vflt16(p, 1, &out, 1, vDSP_Length(n))
            var scale: Float = 1 / 32768
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
            return out
        }
        return []
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        b.frameLength = AVAudioFrameCount(samples.count)
        if let p = b.floatChannelData?[0] {
            p.update(from: samples, count: samples.count)
        } else if let p = b.int16ChannelData?[0] {
            for i in 0..<samples.count {
                p[i] = Int16(max(-32768, min(32767, (samples[i] * 32768).rounded())))
            }
        } else {
            return nil
        }
        return b
    }
}
