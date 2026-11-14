import AVFoundation
import Foundation

/// Which side of the conversation a line or clip belongs to.
enum Side: String, Hashable, Codable, Sendable {
    case theirs, mine
}

// MARK: Session clock

/// The monotonic clock (seconds) that `UILine.audioRange` and the recorder share. Track B owns the conversation's
/// session clock: it only needs to conform (or wrap its clock in `ClosureSessionClock`) and hand the same instance to
/// `RingAudioClipRecorder(clock:)`, so a recognizer result range mapped to this clock can be clipped directly.
/// The clock must never go backwards (no wall-clock time: a time zone change or clock set must not move it).
protocol SessionClock: Sendable {
    var now: TimeInterval { get }
}

/// Seconds since the process started counting (`ProcessInfo.systemUptime`): monotonic, keeps running while the
/// app is in the background (the audio session keeps it alive).
struct MonotonicSessionClock: SessionClock {
    init() {}
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Adapts any clock (tests, B's own session clock) to `SessionClock`.
struct ClosureSessionClock: SessionClock {
    let read: @Sendable () -> TimeInterval
    init(_ read: @escaping @Sendable () -> TimeInterval) { self.read = read }
    var now: TimeInterval { read() }
}

// MARK: Protocol

/// Rolling PCM ring buffers (mine + theirs, 20 s each, memory only) and `clip(range)` → WAV for a flagged line.
/// Nothing is written to disk here: only `FeedbackQueue` stores a clip, and only for a line the user flags.
protocol AudioClipRecording: AnyObject, Sendable {
    /// The recorder clock (seconds) that `UILine.audioRange` is expressed in.
    var now: TimeInterval { get }
    /// Appends `pcm` that ends now (on the recorder clock).
    func append(_ pcm: [Int16], sampleRate: Int, side: Side)
    /// Appends `pcm` whose last sample was captured at `endingAt` (recorder clock).
    func append(_ pcm: [Int16], sampleRate: Int, side: Side, endingAt: TimeInterval)
    /// The WAV bytes for `range` on `side`, or nil when nothing of it is in the buffer (overwritten or never heard).
    func clip(_ range: ClosedRange<TimeInterval>, side: Side) -> Data?
    /// Drops everything buffered (sharing turned off, conversation cleared).
    func reset()
}

extension AudioClipRecording {
    func append(_ pcm: [Int16], sampleRate: Int, side: Side) {
        append(pcm, sampleRate: sampleRate, side: side, endingAt: now)
    }
}

/// Records nothing (demo mode, tests).
final class NoopAudioClipRecorder: AudioClipRecording, @unchecked Sendable {
    init() {}
    var now: TimeInterval { 0 }
    func append(_ pcm: [Int16], sampleRate: Int, side: Side, endingAt: TimeInterval) {}
    func clip(_ range: ClosedRange<TimeInterval>, side: Side) -> Data? { nil }
    func reset() {}
}

// MARK: Ring recorder

/// Two 16 kHz mono rings of `seconds` each. Thread-safe (the mic tap appends on the audio thread, the board path on
/// the main actor, `clip` runs on the main actor): every access holds one lock and does only copying.
///
/// Each ring keeps the samples plus the spans of time they cover (`Segment`): audio arrives in bursts (the board
/// only sends while someone talks), so sample index and time are related per contiguous span. A chunk whose start
/// is within `joinTolerance` of the previous span's end extends that span; one stamped earlier than that end is moved
/// to it (spans never overlap). `clip` copies the samples of every span
/// overlapping the range and fills the gaps between them with silence.
final class RingAudioClipRecorder: AudioClipRecording, @unchecked Sendable {
    static let sampleRate = 16_000

    private let clock: SessionClock
    private let lock = NSLock()
    private var rings: [Side: Ring]

    /// `seconds` per side (20 s by default).
    init(clock: SessionClock = MonotonicSessionClock(), seconds: Double = 20) {
        self.clock = clock
        let capacity = max(1, Int(seconds * Double(Self.sampleRate)))
        rings = [.mine: Ring(capacity: capacity), .theirs: Ring(capacity: capacity)]
    }

    var now: TimeInterval { clock.now }

    func append(_ pcm: [Int16], sampleRate: Int, side: Side, endingAt: TimeInterval) {
        guard !pcm.isEmpty, sampleRate > 0 else { return }
        let samples = sampleRate == Self.sampleRate ? pcm : Self.resample(pcm, from: sampleRate, to: Self.sampleRate)
        let start = endingAt - Double(samples.count) / Double(Self.sampleRate)
        lock.lock()
        rings[side]?.write(samples, startingAt: start)
        lock.unlock()
    }

    func clip(_ range: ClosedRange<TimeInterval>, side: Side) -> Data? {
        lock.lock()
        let samples = rings[side]?.read(range)
        lock.unlock()
        guard let samples, !samples.isEmpty else { return nil }
        return WAV.encode(samples, sampleRate: Self.sampleRate)
    }

    func reset() {
        lock.lock()
        for side in [Side.mine, .theirs] { rings[side]?.clear() }
        lock.unlock()
    }

    /// Linear interpolation; good enough for a clip a developer listens to.
    static func resample(_ pcm: [Int16], from: Int, to: Int) -> [Int16] {
        guard from != to, pcm.count > 1 else { return pcm }
        let outCount = max(1, Int((Double(pcm.count) * Double(to) / Double(from)).rounded()))
        let step = Double(pcm.count - 1) / Double(max(outCount - 1, 1))
        var out = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let x = Double(i) * step
            let i0 = Int(x), i1 = min(i0 + 1, pcm.count - 1)
            let f = x - Double(i0)
            out[i] = Int16(clamping: Int((Double(pcm[i0]) * (1 - f) + Double(pcm[i1]) * f).rounded()))
        }
        return out
    }

    /// One side's ring.
    struct Ring {
        /// A contiguous span: `count` samples starting at absolute sample index `first`, captured from `start`.
        struct Segment {
            var first: Int
            var count: Int
            var start: TimeInterval
            var end: TimeInterval { start + Double(count) / Double(RingAudioClipRecorder.sampleRate) }
        }

        static let joinTolerance: TimeInterval = 0.05

        let capacity: Int
        private var buffer: [Int16]
        /// Samples written since the start (absolute index of the next sample).
        private(set) var written = 0
        private(set) var segments: [Segment] = []

        init(capacity: Int) {
            self.capacity = capacity
            buffer = [Int16](repeating: 0, count: capacity)
        }

        /// The oldest absolute index still in the buffer.
        var oldest: Int { max(0, written - capacity) }

        mutating func clear() {
            written = 0
            segments.removeAll()
        }

        mutating func write(_ samples: [Int16], startingAt start: TimeInterval) {
            // A chunk longer than the ring keeps only its tail
            var samples = samples[...]
            var start = start
            if samples.count > capacity {
                let drop = samples.count - capacity
                start += Double(drop) / Double(RingAudioClipRecorder.sampleRate)
                samples = samples.dropFirst(drop)
            }
            // A chunk stamped before the previous span ends (callback jitter) follows it instead: overlapping spans
            // would play the same stretch twice in a clip
            if let last = segments.last, start < last.end { start = last.end }
            if var last = segments.last, abs(last.end - start) <= Self.joinTolerance {
                last.count += samples.count
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(first: written, count: samples.count, start: start))
            }
            var index = written % capacity
            for s in samples {
                buffer[index] = s
                index += 1
                if index == capacity { index = 0 }
            }
            written += samples.count
            // Spans that were overwritten entirely go; the oldest one is trimmed to what is left
            let oldest = self.oldest
            segments.removeAll { $0.first + $0.count <= oldest }
            if var head = segments.first, head.first < oldest {
                let cut = oldest - head.first
                head.first += cut
                head.count -= cut
                head.start += Double(cut) / Double(RingAudioClipRecorder.sampleRate)
                segments[0] = head
            }
        }

        /// The samples covering `range` (silence between spans); nil when no span overlaps it.
        func read(_ range: ClosedRange<TimeInterval>) -> [Int16]? {
            let rate = Double(RingAudioClipRecorder.sampleRate)
            let hits = segments.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
            guard let firstHit = hits.first else { return nil }
            let clipStart = max(range.lowerBound, firstHit.start)
            var out: [Int16] = []
            var cursor = clipStart
            for seg in hits {
                let from = max(range.lowerBound, seg.start)
                let to = min(range.upperBound, seg.end)
                guard to > from else { continue }
                if from > cursor {
                    let gap = min(Int(((from - cursor) * rate).rounded()), capacity)
                    out.append(contentsOf: repeatElement(0, count: gap))
                }
                let a = min(seg.count, max(0, Int(((from - seg.start) * rate).rounded())))
                let b = min(seg.count, max(a, Int(((to - seg.start) * rate).rounded())))
                for i in a..<b { out.append(buffer[(seg.first + i) % capacity]) }
                cursor = to
            }
            return out.isEmpty ? nil : out
        }
    }
}

// MARK: WAV

/// 16-bit PCM mono WAV (RIFF, 44-byte header).
enum WAV {
    static func encode(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                          // fmt chunk size
        u16(1)                           // PCM
        u16(1)                           // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))      // byte rate
        u16(2)                           // block align
        u16(16)                          // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }

    /// Seconds of audio in a WAV produced by `encode`; nil when the header is not one of ours.
    static func duration(_ data: Data) -> Double? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 {
            data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        let rate = Double(u32(24)), bytes = Double(u32(40))
        guard rate > 0 else { return nil }
        return bytes / 2 / rate
    }
}

// MARK: Mic tap

/// Where the engine's mic path hands its converted (recognizer-format, pre-gate) buffers so "my" ring can be filled
/// without the engine knowing about the recorder: `install` (once, at launch) makes `feed` the `MicSource.tap` (one
/// hook line in `MicSource.handle`); `connect` only changes the recorder and the side under the lock, so the audio
/// thread never sees the tap itself change. Runs on the audio thread: only a lock-protected copy.
enum MicPCMTap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var target: (any AudioClipRecording)?
    nonisolated(unsafe) private static var side: Side = .mine

    /// Makes `feed` the mic tap. Call once at launch, before the mic starts; later calls do nothing.
    static func install() {
        MicSource.installTap { MicPCMTap.feed($0) }
    }

    /// Sets the recorder the mic feeds, and which side the mic is (phone-only mode routes it to `.theirs` once the
    /// engine has moved the mic). Never touches `MicSource.tap`.
    static func connect(_ recorder: (any AudioClipRecording)?, side: Side = .mine) {
        lock.lock()
        target = recorder
        self.side = side
        lock.unlock()
    }

    static func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let recorder = target, side = self.side
        lock.unlock()
        guard let recorder, let pcm = int16Samples(buffer) else { return }
        recorder.append(pcm, sampleRate: Int(buffer.format.sampleRate), side: side)
    }

    /// Mono Int16 samples of the first channel (Int16 or Float32 buffers).
    static func int16Samples(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        if let p = buffer.int16ChannelData { return Array(UnsafeBufferPointer(start: p[0], count: n)) }
        if let p = buffer.floatChannelData {
            return (0..<n).map { Int16(clamping: Int((max(-1, min(1, p[0][$0])) * 32767).rounded())) }
        }
        return nil
    }
}
