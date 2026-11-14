import Foundation

// Pure helpers behind the Live screen's hot values: the board voice level for the dial ring and the audio range of
// each transcript line. The controller owns one of each; both are unit-tested (LiveSignalsTests).

/// The board's voice level for the dial ring, computed like the board's own ring (firmware/main/audio_in.c,
/// `ring_percent`): the RMS of a packet in dBFS, -55 dBFS (faint, far) … -25 dBFS (close, clear) → 0…1.
enum BoardLevelMeter {
    static let minDB = -55.0
    static let maxDB = -25.0
    /// No packet for this long: the board's VAD closed and the ring falls to 0.
    static let silenceAfter: TimeInterval = 0.3

    /// RMS of 16-bit PCM in dBFS; -infinity for empty or all-zero input.
    static func dbfs(_ pcm: [Int16]) -> Double {
        guard !pcm.isEmpty else { return -.infinity }
        var sum = 0.0
        for s in pcm {
            let v = Double(s) / 32768
            sum += v * v
        }
        let rms = (sum / Double(pcm.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    /// 0…1 for the ring.
    static func level(_ pcm: [Int16]) -> Double {
        let db = dbfs(pcm)
        guard db.isFinite else { return 0 }
        return min(max((db - minDB) / (maxDB - minDB), 0), 1)
    }
}

/// Maps recognizer results to ranges on the `SessionClock` (`UILine.audioRange`), the clock the clip recorder
/// (`RingAudioClipRecorder`) stamps its rings with on arrival, so `recorder.clip(line.audioRange, side:)` cuts the
/// phrase out directly. Times are when audio arrived in the app, in seconds of `MonotonicSessionClock`.
///
/// Their side: the board streams a phrase as a run of packets. A result's range ends when the last packet before it
/// arrived and starts the result's audio length earlier (the recognizer's own result range); without a length, it
/// starts at the first packet of the run. Without board packets (phone-only: the iPhone mic feeds their recognizer
/// inside the engine) the range ends when the result arrives.
///
/// My side: each result (partial or final) covers `arrival − audioLength … arrival` (the gated mic drops silence,
/// so this is the speech itself); a turn's range is the union of its results' ranges.
struct AudioRanges {
    /// A pause between board packets longer than this starts a new run.
    var runGap: TimeInterval = 0.6
    /// Board packets older than this are not taken as the end of a result (it came from another source).
    var staleAfter: TimeInterval = 5

    private(set) var runStart: TimeInterval?
    private(set) var lastPacket: TimeInterval?
    private var turns: [Int: ClosedRange<TimeInterval>] = [:]

    init() {}

    /// A board packet carrying `seconds` of audio arrived at `t`.
    mutating func boardPacket(at t: TimeInterval, seconds: TimeInterval) {
        if let last = lastPacket, t - last <= runGap, runStart != nil {
            // same run
        } else {
            runStart = t - max(0, seconds)
        }
        lastPacket = t
    }

    /// The range of their result arriving at `t` with `audio` seconds (nil or 0 when the recognizer gave none).
    func theirs(at t: TimeInterval, audio: TimeInterval?) -> ClosedRange<TimeInterval>? {
        let fromBoard = lastPacket.map { t - $0 <= staleAfter } ?? false
        let end = fromBoard ? lastPacket! : t
        if let audio, audio > 0 { return max(0, end - audio)...end }
        guard fromBoard, let start = runStart, start <= end else { return nil }
        return start...end
    }

    /// Adds my result (turn `turn`, `audio` seconds, arriving at `t`) and returns the turn's range so far.
    mutating func mine(turn: Int, at t: TimeInterval, audio: TimeInterval) -> ClosedRange<TimeInterval> {
        let r = max(0, t - max(0, audio))...t
        let merged = turns[turn].map { min($0.lowerBound, r.lowerBound)...max($0.upperBound, r.upperBound) } ?? r
        turns[turn] = merged
        // Only the latest few turns can still change
        if turns.count > 8, let oldest = turns.keys.min() { turns[oldest] = nil }
        return merged
    }

    mutating func reset() {
        runStart = nil
        lastPacket = nil
        turns.removeAll()
    }
}
