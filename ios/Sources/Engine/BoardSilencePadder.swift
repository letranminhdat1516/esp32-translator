import Foundation

/// Fills pauses in board audio with digital silence for the board's recognizer, so SpeechTranscriber ends the
/// phrase by its own endpointing instead of a `finalize` call.
///
/// The board streams only while its VAD hears speech (plus an 800 ms hangover) and then goes quiet. Finalizing
/// on that pause (the old 0.25 s timer) corrupted SpeechTranscriber's following utterances: in
/// ios/Tools/latency-harness (`PAD=silence` vs the app's finalize, en-US with .fastResults) any
/// `analyzer.finalize` (through nil or through the last audio, with or without .fastResults) left 10 of 12
/// utterances as punctuation runs like ",......" (WER 0.40), while feeding 20 ms frames of digital silence while
/// packets pause damaged 0 of 12 (WER 0) and gave the final phrase about 200 ms sooner (median).
///
/// Timing: after a packet the next one is expected once its audio has played out; padding starts `grace` later
/// (BLE delivers two 20 ms packets per 30-45 ms connection event, so short gaps are normal). The first pad
/// catches up on the whole gap at once and then one frame follows per `frame`, so the recognizer's audio keeps
/// pace with the wall clock as in the harness, which padded each 20 ms frame the board did not send. Padding
/// stops after `limit` of silence (the recognizer has long ended the phrase; it saves CPU) and whenever `pad`
/// reports the recognizer gone. Nothing is padded before the first packet, and a real packet cancels the pending
/// pad before it is fed.
///
/// Main actor: `audioArrived` and the pad ticks run on the same actor as the feed of real audio, so silence
/// never interleaves with it out of order. Padding is not board audio: it never reaches the controller (the
/// conversation's activity and the "recognizer died" signal still come only from real packets).
@MainActor
final class BoardSilencePadder {
    struct Config {
        /// One silent frame, as the board's 20 ms packets and the harness's PAD=silence frames
        var frame: TimeInterval = 0.02
        /// Wait this long after the expected next packet before padding (BLE delivery jitter)
        var grace: TimeInterval = 0.1
        /// Stop padding after this much continuous silence
        var limit: TimeInterval = 3
    }

    /// Runs `work` after `delay` seconds on the main actor; returns a cancel function
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void

    let config: Config
    private let now: () -> TimeInterval
    private let schedule: Schedule
    /// Feeds `frames` silent frames; false when the recognizer is gone (padding stops)
    private let pad: @MainActor (_ frames: Int) -> Bool

    /// Wall-clock time at which the audio fed so far has played out (nil before the first packet)
    private var audioEnd: TimeInterval?
    private var paddedFrames = 0
    private var cancelTick: (() -> Void)?

    init(config: Config = Config(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = BoardSilencePadder.onMainQueue,
         pad: @escaping @MainActor (_ frames: Int) -> Bool) {
        self.config = config
        self.now = now
        self.schedule = schedule
        self.pad = pad
    }

    /// A pad tick is scheduled or silence is being fed
    var isPadding: Bool { cancelTick != nil }

    /// A real packet of `seconds` audio is about to be fed: cancels the pending pad and waits for the next gap
    func audioArrived(seconds: TimeInterval) {
        cancel()
        let t = now()
        let end = max(audioEnd ?? t, t) + seconds
        audioEnd = end
        paddedFrames = 0
        arm(after: end - t + config.grace)
    }

    /// No more padding until the next packet (engine stopped or torn down)
    func stop() {
        cancel()
        audioEnd = nil
        paddedFrames = 0
    }

    private var limitFrames: Int { max(1, Int((config.limit / config.frame).rounded())) }

    private func arm(after delay: TimeInterval) {
        cancelTick = schedule(max(0, delay)) { [weak self] in self?.tick() }
    }

    private func cancel() {
        cancelTick?()
        cancelTick = nil
    }

    private func tick() {
        cancelTick = nil
        guard let end = audioEnd else { return }
        // Frames owed since the fed audio played out (a small epsilon absorbs timer rounding)
        let owed = Int(((now() - end) / config.frame + 1e-6).rounded(.down))
        let frames = min(max(0, owed), limitFrames - paddedFrames)
        if frames > 0 {
            guard pad(frames) else { return }
            paddedFrames += frames
            audioEnd = end + Double(frames) * config.frame
        }
        guard paddedFrames < limitFrames else { return }
        arm(after: config.frame)
    }

    /// The real scheduler: DispatchQueue.main
    static func onMainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
