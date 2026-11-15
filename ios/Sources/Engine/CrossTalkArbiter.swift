import Foundation

/// Decides who is really talking when the board mic (the other person, "họ") and my mic (AirPods or the iPhone,
/// "tôi") carry speech at the same time, so each recognizer hears only its own person.
///
/// Both mics hear both people. The board, held by the other person, hears the user faintly from 0.5-1.5 m; my mic
/// hears the other person faintly (AirPods: 20-30 dB below my voice, the iPhone mic: about 10 dB). When both sides
/// stream at once, the side whose own talker is speaking takes the floor and the other side's audio is replaced
/// with silence for that stretch (`CrossTalkGuard` applies it; silence keeps the recognizers' timing, see
/// `BoardSilencePadder`).
///
/// Per side, per 20 ms frame:
/// - Floor: the `floorPercentile` of the last `floorWindow` frame levels (a histogram, no sorting). Both sides
///   stream only while their gate is open, and every opening starts with background (the gate's pre-roll).
/// - Level above the floor (SNR), as an envelope: it follows a louder frame at once, holds `hold`, then falls
///   `releasePerSecond`, so the gaps between syllables do not hand the floor over.
/// - Score: the envelope minus the side's own talker's usual SNR (the `ownPercentile` of its frames while it held
///   the floor; `defaultOwnDB` until `learnFrames` were seen). The own talker scores about 0 on each side, the far
///   talker 10-30 dB below, whatever the mic's gain or noise suppression (the iPhone's voice processing pushes its
///   floor far below the board's, so raw SNRs are not comparable between the sides).
///
/// Ownership: a side is active while its envelope is `activeDB` above its floor. With no owner a lone active side
/// takes the floor, and of two active sides the one leading by `takeDB`. An owner keeps it until it goes inactive
/// or the other side leads by `switchDB` (`takeDB` during its first `settle`: board packets arrive about 150 ms
/// after my mic hears the same voice, so my mic's gate may open first on the other person). Two active sides
/// closer than `takeDB` with no settled owner are both let through, as before this arbitration.
///
/// Pure: the caller passes the time; `CrossTalkGuard` adds the lock, the clock and the buffers.
struct CrossTalkArbiter {
    enum Side: String, Sendable, CaseIterable {
        case mine, theirs

        var other: Side { self == .mine ? .theirs : .mine }
    }

    struct Config {
        /// Floor: this percentile of the last `floorWindow` frames (10 s of streamed audio)
        var floorWindow = 500
        var floorPercentile = 0.05
        /// A side is active while its envelope is this far above its floor
        var activeDB: Float = 8
        /// The envelope holds its peak this long, then falls this fast (a 35 dB voice lets go about 0.7 s after
        /// its last word)
        var hold: TimeInterval = 0.25
        var releasePerSecond: Float = 60
        /// The own talker's SNR: this percentile of the last `ownWindow` active frames the side held the floor
        /// with, once `learnFrames` were seen; `defaultOwnDB` before
        var ownWindow = 500
        var ownPercentile = 0.9
        var learnFrames = 100
        var defaultOwnDB: Float = 30
        /// Score lead that takes the floor with no owner or from an owner younger than `settle`…
        var takeDB: Float = 3
        var settle: TimeInterval = 0.4
        /// …and from a settled owner (two people really talking over each other do not flap)
        var switchDB: Float = 8
    }

    struct Decision: Equatable {
        /// Replace this frame with silence
        var suppress: Bool
        var owner: Side?
        /// The owner changed with this frame
        var changed: Bool
    }

    let config: Config
    private(set) var owner: Side?
    private var ownerSince: TimeInterval = 0
    private var tracks: [Side: Track]

    init(config: Config = Config()) {
        self.config = config
        tracks = [.mine: Track(config), .theirs: Track(config)]
    }

    /// One frame of `side` at `time` (seconds, any monotonic clock shared by both sides)
    mutating func observe(_ side: Side, levelDB: Float, at time: TimeInterval) -> Decision {
        let before = owner
        tracks[side]!.add(levelDB: levelDB, at: time)
        resolve(at: time)
        if owner == side { tracks[side]!.learnOwn(activeDB: config.activeDB) }
        return Decision(suppress: owner != nil && owner != side, owner: owner, changed: owner != before)
    }

    /// The owner at `time` if it is still active then (no frame needed; for tests and diagnostics)
    func ownerAt(_ time: TimeInterval) -> Side? {
        guard let owner, tracks[owner]!.envelope(at: time) >= config.activeDB else { return nil }
        return owner
    }

    /// Envelope above the floor and score of `side` at `time` (diagnostics)
    func state(_ side: Side, at time: TimeInterval) -> (snrDB: Float, scoreDB: Float) {
        let t = tracks[side]!
        return (t.envelope(at: time), t.score(at: time))
    }

    /// Forgets everything (engine stopped or torn down)
    mutating func reset() {
        owner = nil
        tracks = [.mine: Track(config), .theirs: Track(config)]
    }

    /// Forgets one side's floor and own level (my mic moved between AirPods and the iPhone)
    mutating func reset(_ side: Side) {
        if owner == side { owner = nil }
        tracks[side] = Track(config)
    }

    private mutating func resolve(at time: TimeInterval) {
        let mine = tracks[.mine]!, theirs = tracks[.theirs]!, activeDB = config.activeDB
        func track(_ s: Side) -> Track { s == .mine ? mine : theirs }
        func active(_ s: Side) -> Bool { track(s).envelope(at: time) >= activeDB }
        func lead(_ s: Side) -> Float { track(s).score(at: time) - track(s.other).score(at: time) }
        if let o = owner, !active(o) { owner = nil }

        guard let o = owner else {
            switch (active(.mine), active(.theirs)) {
            case (true, true):
                if lead(.mine) >= config.takeDB { take(.mine, at: time) }
                else if lead(.theirs) >= config.takeDB { take(.theirs, at: time) }
            case (true, false): take(.mine, at: time)
            case (false, true): take(.theirs, at: time)
            case (false, false): break
            }
            return
        }
        let challenger = o.other
        guard active(challenger) else { return }
        let young = time - ownerSince < config.settle
        let gain = lead(challenger)
        if gain >= (young ? config.takeDB : config.switchDB) {
            take(challenger, at: time)
        } else if young, gain > -config.takeDB {
            owner = nil   // too close to call before the owner settled
        }
    }

    private mutating func take(_ side: Side, at time: TimeInterval) {
        owner = side
        ownerSince = time
    }

    /// One side's floor, envelope and own talker's level
    private struct Track {
        let config: Config
        private var floorLevels: Histogram
        private var ownLevels: Histogram
        private(set) var floorDB: Float = 0
        private var lastSNR: Float = 0
        private var peak: Float = -.infinity
        private var peakAt: TimeInterval = 0

        init(_ config: Config) {
            self.config = config
            floorLevels = Histogram(low: -100, high: 0, window: config.floorWindow)
            ownLevels = Histogram(low: 0, high: 100, window: config.ownWindow)
        }

        mutating func add(levelDB: Float, at time: TimeInterval) {
            floorLevels.add(levelDB)
            floorDB = floorLevels.percentile(config.floorPercentile) ?? levelDB
            lastSNR = levelDB - floorDB
            if lastSNR >= envelope(at: time) {
                peak = lastSNR
                peakAt = time
            }
        }

        /// The frame just added counts toward the own talker's level (the side holds the floor)
        mutating func learnOwn(activeDB: Float) {
            if lastSNR >= activeDB { ownLevels.add(lastSNR) }
        }

        func envelope(at time: TimeInterval) -> Float {
            peak - config.releasePerSecond * Float(max(0, time - peakAt - config.hold))
        }

        var ownDB: Float {
            ownLevels.count >= config.learnFrames
                ? ownLevels.percentile(config.ownPercentile) ?? config.defaultOwnDB : config.defaultOwnDB
        }

        func score(at time: TimeInterval) -> Float { envelope(at: time) - ownDB }
    }
}

/// Percentiles of the last `window` values, in 1 dB bins between `low` and `high` (values outside are clamped):
/// O(bins) per query, no sorting on the audio thread
struct Histogram {
    private let low: Float
    private var counts: [Int]
    private var ring: [Int]
    private var head = 0
    private(set) var count = 0

    init(low: Float, high: Float, window: Int) {
        self.low = low
        counts = [Int](repeating: 0, count: max(1, Int(high - low) + 1))
        ring = [Int](repeating: 0, count: max(1, window))
    }

    mutating func add(_ value: Float) {
        let bin = value.isFinite ? min(counts.count - 1, max(0, Int((value - low).rounded(.down)))) : 0
        if count == ring.count { counts[ring[head]] -= 1 } else { count += 1 }
        ring[head] = bin
        counts[bin] += 1
        head = (head + 1) % ring.count
    }

    /// The bin holding the `p` (0…1) percentile, as its lower edge; nil while empty
    func percentile(_ p: Double) -> Float? {
        guard count > 0 else { return nil }
        let rank = min(count - 1, Int(Double(count - 1) * p))
        var seen = 0
        for (bin, n) in counts.enumerated() {
            seen += n
            if seen > rank { return low + Float(bin) }
        }
        return low + Float(counts.count - 1)
    }
}
