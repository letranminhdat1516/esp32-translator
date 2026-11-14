import Foundation

/// Which side of the conversation a line or clip belongs to.
enum Side: String, Hashable, Codable, Sendable {
    case theirs, mine
}

/// Rolling PCM ring buffers (mine + theirs, 20 s each, memory only) and `clip(range)` → WAV for a flagged line.
/// Track C implements it; nothing is written unless the user flags a line.
protocol AudioClipRecording: AnyObject, Sendable {
    /// The recorder clock (seconds) that `UILine.audioRange` is expressed in.
    var now: TimeInterval { get }
    func append(_ pcm: [Int16], sampleRate: Int, side: Side)
    /// The WAV bytes for `range` on `side`, or nil when it has already been overwritten.
    func clip(_ range: ClosedRange<TimeInterval>, side: Side) -> Data?
}

/// Records nothing (sharing off, demo mode, tests).
final class NoopAudioClipRecorder: AudioClipRecording, @unchecked Sendable {
    init() {}
    var now: TimeInterval { 0 }
    func append(_ pcm: [Int16], sampleRate: Int, side: Side) {}
    func clip(_ range: ClosedRange<TimeInterval>, side: Side) -> Data? { nil }
}
