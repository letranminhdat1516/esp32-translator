import Accelerate
import AVFAudio
import os

/// Own-voice gate for the AirPods mic: passes audio to the Vietnamese recognizer only while the wearer speaks.
///
/// Speech from people nearby, heard just before or after your own words, was the largest source of
/// Vietnamese recognition errors: the recognizer transcribed it and it was translated as if you had said it.
/// The wearer's mouth is a few centimetres from the AirPods mics, so their voice arrives much louder than
/// anyone else's. A 20 ms frame opens the gate only if it is well above the background level, voiced
/// (periodic at a speech pitch) and near the wearer's own learned level. The gate keeps 300 ms of pre-roll
/// so the first syllable is not cut, and closes 0.8 s after the voice stops.
///
/// The background level is a low percentile of the frame levels over the last few seconds. It follows
/// sustained café babble within seconds (the old floor rose 0.5 dB/s and never caught up, so the gate
/// stayed open), and it stays low while you talk because the gaps between syllables keep it down.
///
/// The wearer's level is learned per utterance (90th percentile of its voiced frames), smoothed as the
/// median of the last five utterances weighted by their length, and allowed to rise at most 6 dB per
/// utterance, so one shout does not shut out normal speech. It is forgotten on an audio route change, and relearned when the gate keeps
/// rejecting voice that stands out from the background as much as the wearer's does (a mic gain drop).
///
/// Measured with ios/Tools/vi-harness on synthetic Vietnamese speech in café babble (see the README).
/// Cost: one level, a percentile of 150 values and, only for loud frames, one short autocorrelation per
/// 20 ms frame: about 0.05 % of one Mac core, mic format conversion included. No allocation per frame.
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
        /// Opening needs frames within `nearMarginDB` of the wearer's level (their utterances' 90th
        /// percentile): bystanders and the person you talk to are 15–25 dB quieter at the AirPods mics.
        var nearMarginDB: Float = 8
        /// Holding needs `holdNearMarginDB`; while the voice continues without a gap longer than
        /// `softHoldGap` it only needs `softHoldNearMarginDB`, so the softer end of a sentence is not cut but
        /// someone who starts talking after you have stopped does not hold the gate open
        var holdNearMarginDB: Float = 8
        var softHoldNearMarginDB: Float = 20
        var softHoldGap: TimeInterval = 0.3
        /// Each utterance votes with this percentile of its loud voiced frames
        var userPercentile = 0.9
        /// An utterance needs this much loud voiced speech to teach the wearer's level
        var learnMinSpeech: TimeInterval = 0.5
        /// The level follows the median of the last `learnUtterances` utterances, weighted by their speech
        /// time, rising at most `maxRisePerUtterance` dB per utterance
        var learnUtterances = 5
        var maxRisePerUtterance: Float = 6
        /// While closed the level sinks by this much per second, never more than `maxDecayDB` below the last
        /// learned value (so minutes of listening do not let the other person in)
        var decayPerSecond: Float = 0.05
        var maxDecayDB: Float = 5
        /// Relearn the level after a mic gain drop: the background (5th and 25th percentile) fell at least
        /// `relearnFloorDropDB` below
        /// where it was when the level was learned, and within `relearnWindow` at least `relearnSpeech`
        /// seconds of voiced frames (≥ `relearnMarginDB` above the background) were rejected while lying
        /// where the wearer's voice would be after the same drop (−`nearMarginDB`…+`relearnSlackDB`)
        var relearnMarginDB: Float = 15
        var relearnSlackDB: Float = 4
        var relearnFloorDropDB: Float = 6
        var relearnWindow: TimeInterval = 1.5
        var relearnSpeech: TimeInterval = 0.5
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

    /// Samples waiting to fill a frame, and the frame being analyzed
    private var pending: [Float] = []
    private var pendingCount = 0
    private var frame: [Float] = []
    /// Recent audio while closed (pre-roll plus the onset window), and the pitch analysis window
    private var history = Ring(capacity: 1)
    private var analysis = Ring(capacity: 1)
    private var analysisScratch: [Float] = []

    /// Recent frame levels for the background estimate
    private var levels = Ring(capacity: 1)
    private var sortScratch: [Float] = []
    private(set) var floorDB: Float = -100
    /// 25th percentile of the same window: moves with the background, not with a brief silence
    private var quartileDB: Float = -100
    private var openFloorDB: Float = -100
    private var openQuartileDB: Float = -100

    /// The wearer: learned level (dB) and how far it stands above the background (dB), per-utterance
    /// statistics of the last few utterances, and the current utterance's frames
    private(set) var userLevelDB: Float?
    private var userFloorDB: Float?
    private var userQuartileDB: Float?
    private var recentFloors: [Float] = []
    private var recentWeights: [Float] = []
    private var recentQuartiles: [Float] = []
    private var lastLearnedDB: Float = 0
    private var recentLevels: [Float] = []
    private var utteranceLevels: [Float] = []
    private var utteranceCount = 0
    /// Frames rejected only for being quieter than the wearer's level but standing out like the wearer
    private var rejected: [Bool] = []
    private var rejectedIndex = 0
    private var rejectedCount = 0
    private let resetRequested = OSAllocatedUnfairLock(initialState: false)

    /// Loud and voiced flags for the frames in the onset window (ring)
    private var onset: [Bool] = []
    private var onsetIndex = 0
    private var onsetFilled = 0
    private var speaking = false
    private var silentFor: TimeInterval = 0
    /// Time since the last frame that held the gate open
    private var sinceHeld: TimeInterval = 0

    /// Statistics for diagnostics and the harness
    private(set) var framesAnalyzed = 0
    private(set) var pitchAnalyses = 0

    init(config: Config = Config()) {
        self.config = config
    }

    var isOpen: Bool { speaking }

    /// Forget the wearer's level (audio route or engine configuration changed: the mic and its gain may
    /// be different). Safe to call from any thread; applied before the next buffer.
    func resetWearerLevel() {
        resetRequested.withLock { $0 = true }
    }

    /// Splits the buffer into frames and returns what to send to the recognizer, in order
    func process(_ buffer: AVAudioPCMBuffer) -> [Event] {
        let format = buffer.format
        if format.sampleRate != sampleRate { configure(sampleRate: format.sampleRate) }
        if resetRequested.withLock({ let r = $0; $0 = false; return r }) {
            forgetWearer("route change")
        }
        var events: [Event] = []
        var out: [Float] = []
        let n = Int(buffer.frameLength)
        var i = 0
        while i < n {
            let take = min(frameLength - pendingCount, n - i)
            Self.copy(buffer, from: i, count: take, into: &pending, at: pendingCount)
            pendingCount += take
            i += take
            if pendingCount == frameLength {
                swap(&pending, &frame)
                pendingCount = 0
                step(out: &out, events: &events, format: format)
            }
        }
        if !out.isEmpty, let b = Self.buffer(out, format: format) { events.append(.audio(b)) }
        return events
    }

    // MARK: Per frame

    private func step(out: inout [Float], events: inout [Event], format: AVAudioFormat) {
        framesAnalyzed += 1
        analysis.append(frame)

        let db = Self.levelDB(frame)
        levels.append(db)
        (floorDB, quartileDB) = levels.percentiles(config.floorPercentile, 0.25, scratch: &sortScratch)
        let floor = floorDB
        let level = userLevelDB
        let near = level.map { db >= $0 - config.nearMarginDB } ?? true
        let continuing = sinceHeld <= config.softHoldGap
        let holdMargin = continuing ? config.softHoldNearMarginDB : config.holdNearMarginDB
        let nearish = level.map { db >= $0 - holdMargin } ?? true
        let loud = db > floor + config.openMarginDB && db > config.minDB && near
        let held = db > floor + config.holdMarginDB && db > config.minDB && nearish
        // Voice rejected only for being quieter than the wearer: a candidate for relearning
        // A mic gain drop lowers the background and the wearer's voice by the same amount; someone else
        // talking, or the background going quiet, does not
        var standsOut = false
        if !speaking, !near, let learned = level, let learnedFloor = userFloorDB,
           let learnedQuartile = userQuartileDB, db > config.minDB, db > floor + config.relearnMarginDB,
           learnedQuartile - quartileDB >= config.relearnFloorDropDB {
            let drop = learnedFloor - floor
            let expected = learned - drop
            standsOut = drop >= config.relearnFloorDropDB && db >= expected - config.nearMarginDB
                && db <= expected + config.relearnSlackDB
        }
        // The pitch analysis only runs when the level could open, hold or relearn
        let voiced = (loud || (speaking && held) || standsOut) ? isVoiced() : false

        if speaking {
            if voiced && db > floor + config.openMarginDB && db > config.minDB {
                if utteranceLevels.count < 1500 { utteranceLevels.append(db) }
                utteranceCount += 1
                // Not learned yet (start, route change): estimate from this utterance after 1 s of speech and
                // keep refining it twice a second, so babble cannot hold the gate open until it ends
                if recentLevels.isEmpty, utteranceCount >= 50, utteranceCount % 25 == 0 {
                    userLevelDB = Self.percentile(utteranceLevels, config.userPercentile)
                    lastLearnedDB = userLevelDB!
                }
            }
            if held && voiced {
                silentFor = 0
                sinceHeld = 0
            } else {
                sinceHeld += config.frame
                silentFor += config.frame
                if silentFor > config.hangover {
                    speaking = false
                    learnFromUtterance()
                    Diag.log(String(format: "gate: closed, background %.0f dB, voice %@", floorDB,
                                    userLevelDB.map { String(format: "%.0f dB", $0) } ?? "not learned"))
                    clearOnset()
                    history.removeAll()
                    if !out.isEmpty, let b = Self.buffer(out, format: format) { events.append(.audio(b)) }
                    out.removeAll()
                    events.append(.ended)
                    history.append(frame)
                    return
                }
            }
            out.append(contentsOf: frame)
            return
        }

        history.append(frame)
        if let l = userLevelDB {
            userLevelDB = max(lastLearnedDB - config.maxDecayDB, l - config.decayPerSecond * Float(config.frame))
        }
        if trackRejected(standsOut && voiced) {
            forgetWearer("voice standing out like yours was rejected (mic gain changed?)")
        }

        onset[onsetIndex] = loud && voiced
        onsetIndex = (onsetIndex + 1) % onset.count
        onsetFilled = min(onsetFilled + 1, onset.count)
        var count = 0
        var firstAge = 0
        for age in 0..<onsetFilled where onset[(onsetIndex - 1 - age + onset.count) % onset.count] {
            count += 1
            firstAge = age
        }
        guard count >= config.onsetFrames else { return }

        // Open: send the pre-roll before the first voiced frame, then everything since
        let keep = (firstAge + 1) * frameLength + Int(config.preroll * sampleRate)
        history.appendSuffix(keep, to: &out)
        Diag.log(String(format: "gate: open at %.0f dB, background %.0f dB, voice %@", db, floor,
                        userLevelDB.map { String(format: "%.0f dB", $0) } ?? "not learned"))
        history.removeAll()
        clearOnset()
        speaking = true
        silentFor = 0
        sinceHeld = 0
        openFloorDB = floorDB
        openQuartileDB = quartileDB
        utteranceLevels.removeAll(keepingCapacity: true)
        utteranceCount = 0
    }

    private func clearOnset() {
        for i in onset.indices { onset[i] = false }
        onsetIndex = 0
        onsetFilled = 0
    }

    private func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int(config.frame * sampleRate))
        minLag = Int(sampleRate / config.maxPitchHz)
        maxLag = Int(sampleRate / config.minPitchHz)
        pending = [Float](repeating: 0, count: frameLength)
        frame = pending
        pendingCount = 0
        let analysisLength = max(frameLength, 2 * maxLag + frameLength / 2)
        analysis = Ring(capacity: analysisLength)
        analysisScratch = [Float](repeating: 0, count: analysisLength)
        history = Ring(capacity: Int((config.preroll + config.onsetWindow) * sampleRate) + frameLength)
        let n = max(1, Int((config.floorWindow / config.frame).rounded()))
        levels = Ring(capacity: n)
        sortScratch = [Float](repeating: 0, count: n)
        onset = [Bool](repeating: false, count: max(1, Int((config.onsetWindow / config.frame).rounded())))
        clearOnset()
        rejected = [Bool](repeating: false, count: max(1, Int((config.relearnWindow / config.frame).rounded())))
        speaking = false
        forgetWearer(nil)
    }

    // MARK: Wearer level

    /// At the end of an utterance: its 90th-percentile level becomes one vote (weighted by its speech time)
    private func learnFromUtterance() {
        let speech = Double(utteranceCount) * config.frame
        guard speech >= config.learnMinSpeech else { return }
        let firstVote = recentLevels.isEmpty
        recentLevels.append(Self.percentile(utteranceLevels, config.userPercentile))
        recentWeights.append(Float(speech))
        // The background as it was when the utterance began (during it, the voice lifts the percentiles)
        recentFloors.append(openFloorDB)
        recentQuartiles.append(openQuartileDB)
        if recentLevels.count > config.learnUtterances {
            recentLevels.removeFirst()
            recentWeights.removeFirst()
            recentFloors.removeFirst()
            recentQuartiles.removeFirst()
        }
        // Median weighted by speech time: a 1 s call-out cannot outvote sentences
        let order = recentLevels.indices.sorted { recentLevels[$0] < recentLevels[$1] }
        let half = recentWeights.reduce(0, +) / 2
        var acc: Float = 0
        var target = recentLevels[order.last!]
        for i in order {
            acc += recentWeights[i]
            if acc >= half { target = recentLevels[i]; break }
        }
        let learned = firstVote || userLevelDB == nil
            ? target : min(target, lastLearnedDB + config.maxRisePerUtterance)
        userLevelDB = learned
        lastLearnedDB = learned
        userFloorDB = Self.percentile(recentFloors, 0.5)
        userQuartileDB = Self.percentile(recentQuartiles, 0.5)
    }

    private func forgetWearer(_ reason: String?) {
        if let reason, userLevelDB != nil { Diag.log("gate: forgetting your voice level (\(reason))") }
        userLevelDB = nil
        userFloorDB = nil
        userQuartileDB = nil
        recentLevels.removeAll()
        recentFloors.removeAll()
        recentWeights.removeAll()
        recentQuartiles.removeAll()
        for i in rejected.indices { rejected[i] = false }
        rejectedCount = 0
    }

    /// Slides the relearn window; true when enough wearer-like voice was rejected in it
    private func trackRejected(_ isRejected: Bool) -> Bool {
        guard !rejected.isEmpty else { return false }
        if rejected[rejectedIndex] { rejectedCount -= 1 }
        rejected[rejectedIndex] = isRejected
        if isRejected { rejectedCount += 1 }
        rejectedIndex = (rejectedIndex + 1) % rejected.count
        return Double(rejectedCount) * config.frame >= config.relearnSpeech
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return -100 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    // MARK: Voicing

    /// Peak of the normalized autocorrelation over the pitch range
    private func isVoiced() -> Bool {
        pitchAnalyses += 1
        let n = analysis.count
        guard n > maxLag + 32 else { return false }
        analysis.copyInOrder(to: &analysisScratch)
        var best: Float = 0
        analysisScratch.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            var mean: Float = 0
            vDSP_meanv(base, 1, &mean, vDSP_Length(n))
            var negMean = -mean
            vDSP_vsadd(base, 1, &negMean, base, 1, vDSP_Length(n))
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

    /// Copies `count` samples of the buffer (Float32 or Int16, first channel) into `dst` at `at`
    private static func copy(_ buffer: AVAudioPCMBuffer, from: Int, count: Int, into dst: inout [Float], at: Int) {
        guard count > 0 else { return }
        dst.withUnsafeMutableBufferPointer { d in
            let out = d.baseAddress! + at
            if let p = buffer.floatChannelData?[0] {
                out.update(from: p + from, count: count)
            } else if let p = buffer.int16ChannelData?[0] {
                vDSP_vflt16(p + from, 1, out, 1, vDSP_Length(count))
                var scale: Float = 1 / 32768
                vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(count))
            } else {
                out.update(repeating: 0, count: count)
            }
        }
    }

    static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        var out = [Float](repeating: 0, count: Int(buffer.frameLength))
        copy(buffer, from: 0, count: out.count, into: &out, at: 0)
        return out
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

/// Fixed-capacity ring of samples (or levels): append overwrites the oldest, no reallocation
struct Ring {
    private var storage: [Float]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) { storage = [Float](repeating: 0, count: max(1, capacity)) }

    mutating func append(_ x: Float) {
        storage[head] = x
        head = (head + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    mutating func append(_ xs: [Float]) {
        for x in xs { append(x) }
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }

    /// Appends the newest `n` values, oldest first
    func appendSuffix(_ n: Int, to out: inout [Float]) {
        let k = min(n, count)
        var i = (head - k + storage.count) % storage.count
        for _ in 0..<k {
            out.append(storage[i])
            i = (i + 1) % storage.count
        }
    }

    /// Writes all values, oldest first, to the start of `dst` (which must hold `count` values)
    func copyInOrder(to dst: inout [Float]) {
        var i = (head - count + storage.count) % storage.count
        for j in 0..<count {
            dst[j] = storage[i]
            i = (i + 1) % storage.count
        }
    }

    /// Two percentiles (0…1) of the values, sorted once in `scratch` (at least `count` long)
    func percentiles(_ p: Double, _ q: Double, scratch: inout [Float]) -> (Float, Float) {
        guard count > 0 else { return (-100, -100) }
        copyInOrder(to: &scratch)
        let n = count
        scratch.withUnsafeMutableBufferPointer { vDSP_vsort($0.baseAddress!, vDSP_Length(n), 1) }
        return (scratch[min(n - 1, Int(Double(n - 1) * p))], scratch[min(n - 1, Int(Double(n - 1) * q))])
    }
}
