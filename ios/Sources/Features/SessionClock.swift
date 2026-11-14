import Foundation

/// The one monotonic clock for conversation audio, shared by `UILine.audioRange` (the controller) and the
/// `AudioClipRecorder` ring buffers (track C), so a line's range can be cut straight out of the recorder.
///
/// - Unit: seconds. Origin: the device's boot (`ProcessInfo.systemUptime`), so the values are only comparable
///   within one app run; never persist them or show them to the user.
/// - Monotonic: it never jumps with the wall clock (time zone, NTP, the user setting the time). It does not advance
///   while the device sleeps, which cannot happen while a conversation holds the audio session.
/// - Recorder contract: `append(pcm, …)` stamps the chunk as ending at `SessionClock.now()` at the moment of the
///   call (the audio has just arrived); `clip(range, side:)` returns the samples whose stamps fall in `range`.
/// - Ranges: the controller maps each recognizer result to `end − audioLength … end`, where `end` is when the
///   last audio of the phrase arrived (board packet, or the result itself for the phone mic). See `AudioRanges`.
struct SessionClock: Sendable {
    let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }

    /// The app's clock.
    static let system = SessionClock { ProcessInfo.processInfo.systemUptime }
}
