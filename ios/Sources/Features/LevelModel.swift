import Foundation
import Observation

/// The board voice level 0…1 for the dial ring, throttled to one change per `interval` (66 ms ≈ 15 Hz), so the
/// ring redraws at most 15 times a second and nothing else re-renders. Track B feeds it from the board audio.
@Observable @MainActor
final class LevelModel: LevelSource {
    private(set) var level: Double = 0
    @ObservationIgnored let interval: TimeInterval
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var pending: Double?

    init(interval: TimeInterval = 0.066, level: Double = 0) {
        self.interval = interval
        self.level = LevelRing.clamped(level)
    }

    /// Takes a new reading; publishes it when `interval` has passed since the last publish, else keeps it as the
    /// pending value (the next push or `flush` publishes the latest). Returns whether it published.
    @discardableResult
    func push(_ value: Double, at now: Date = Date()) -> Bool {
        let v = LevelRing.clamped(value)
        guard now.timeIntervalSince(lastPublish) >= interval else {
            pending = v
            return false
        }
        pending = nil
        lastPublish = now
        if v != level { level = v }
        return true
    }

    /// Publishes a held value (on silence or stop).
    func flush(at now: Date = Date()) {
        guard let p = pending else { return }
        pending = nil
        lastPublish = now
        level = p
    }
}

/// Their and my partial (unfinished) phrases, kept apart from `UIState.lines` so a partial update re-renders only
/// the partial row. Track B moves the controller's writes here.
@Observable @MainActor
final class PartialModel {
    var theirs = ""
    var mine = ""
    init() {}
}
