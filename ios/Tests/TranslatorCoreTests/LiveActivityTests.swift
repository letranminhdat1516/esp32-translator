import Foundation
import Testing
@testable import TranslatorCore

// Track D: the Live Activity's coalescing, controller, driver, observer and button bridge, with an injected clock.

private func st(_ translation: String, micOn: Bool = true, battery: Int? = 88) -> TranslatorActivityState {
    TranslatorActivityState(listening: true, boardBattery: battery, theirs: "t", translation: translation, micOn: micOn)
}

/// A clock and a scheduler the test advances by hand.
@MainActor
private final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var timers: [(due: Date, work: @MainActor () -> Void)] = []

    var scheduler: CoalescingLiveActivityController.Scheduler {
        { [unowned self] delay, work in self.timers.append((self.now.addingTimeInterval(delay), work)) }
    }

    var pendingTimers: Int { timers.count }

    /// Moves the clock forward, firing due timers in order.
    func advance(_ seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let i = timers.indices.min(by: { timers[$0].due < timers[$1].due }), timers[i].due <= target {
            let t = timers.remove(at: i)
            now = max(now, t.due)
            t.work()
        }
        now = target
    }
}

@MainActor
private final class FakeBackend: LiveActivityBackend {
    enum Call: Equatable {
        case request(TranslatorActivityStatic, TranslatorActivityState, stale: Date)
        case update(TranslatorActivityState, stale: Date)
        case end(TranslatorActivityState?)
    }

    struct Refused: Error {}

    var areActivitiesEnabled = true
    var failRequest = false
    var calls: [Call] = []
    var updates: [TranslatorActivityState] {
        calls.compactMap { if case .update(let s, _) = $0 { s } else { nil } }
    }

    func request(_ info: TranslatorActivityStatic, _ state: TranslatorActivityState, staleDate: Date) async throws {
        calls.append(.request(info, state, stale: staleDate))
        if failRequest { throw Refused() }
    }

    func update(_ state: TranslatorActivityState, staleDate: Date) async { calls.append(.update(state, stale: staleDate)) }
    func end(_ state: TranslatorActivityState?) async { calls.append(.end(state)) }
}

/// Records what the driver asks for.
@MainActor
private final class RecordingController: LiveActivityControlling {
    enum Call: Equatable {
        case start(String, String, TranslatorActivityState)
        case update(TranslatorActivityState)
        case end
    }

    var calls: [Call] = []
    func start(languageCode: String, languageName: String, state: TranslatorActivityState) {
        calls.append(.start(languageCode, languageName, state))
    }
    func update(_ state: TranslatorActivityState) { calls.append(.update(state)) }
    func end() { calls.append(.end) }
}

@Suite struct LiveActivityCoalescerTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func firstUpdateAfterStartWaitsForTheInterval() {
        var c = LiveActivityCoalescer(interval: 1.5)
        c.started(with: st("a"), at: t0)
        #expect(c.offer(st("b"), at: t0.addingTimeInterval(0.5)) == .schedule(after: 1.0))
        #expect(c.timerArmed)
        // Later offers while armed replace the pending state without another timer
        #expect(c.offer(st("c"), at: t0.addingTimeInterval(1.0)) == .none)
        #expect(c.offer(st("d"), at: t0.addingTimeInterval(1.2)) == .none)
        #expect(c.fire(at: t0.addingTimeInterval(1.5)) == .send(st("d")))
        #expect(c.pending == nil)
        #expect(!c.timerArmed)
    }

    @Test func sendsImmediatelyWhenTheIntervalHasPassed() {
        var c = LiveActivityCoalescer(interval: 1.5)
        c.started(with: st("a"), at: t0)
        #expect(c.offer(st("b"), at: t0.addingTimeInterval(2)) == .send(st("b")))
        #expect(c.offer(st("c"), at: t0.addingTimeInterval(3)) == .schedule(after: 0.5))
    }

    @Test func unchangedStatesAreDropped() {
        var c = LiveActivityCoalescer(interval: 1.5)
        c.started(with: st("a"), at: t0)
        #expect(c.offer(st("a"), at: t0.addingTimeInterval(5)) == .none)
        // A change and back before the trailing timer: nothing to send
        #expect(c.offer(st("b"), at: t0.addingTimeInterval(5)) == .send(st("b")))
        #expect(c.offer(st("c"), at: t0.addingTimeInterval(5.5)) == .schedule(after: 1.0))
        #expect(c.offer(st("b"), at: t0.addingTimeInterval(6)) == .none)
        #expect(c.fire(at: t0.addingTimeInterval(6.5)) == .none)
    }

    @Test func anEarlyTimerReArms() {
        var c = LiveActivityCoalescer(interval: 1.5)
        c.started(with: st("a"), at: t0)
        _ = c.offer(st("b"), at: t0.addingTimeInterval(0.1))
        #expect(c.fire(at: t0.addingTimeInterval(1.0)) == .schedule(after: 0.5))
        #expect(c.fire(at: t0.addingTimeInterval(1.5)) == .send(st("b")))
    }

    @Test func neverMoreThanOneSendPerInterval() {
        var c = LiveActivityCoalescer(interval: 1.5)
        c.started(with: st("start"), at: t0)
        var sends: [Date] = [t0]
        var timerDue: Date?
        // A partial every 100 ms for 20 s
        for i in 1...200 {
            let now = t0.addingTimeInterval(Double(i) * 0.1)
            if let due = timerDue, due <= now {
                timerDue = nil
                switch c.fire(at: due) {
                case .send: sends.append(due)
                case .schedule(let after): timerDue = due.addingTimeInterval(after)
                case .none: break
                }
            }
            switch c.offer(st("p\(i)"), at: now) {
            case .send: sends.append(now)
            case .schedule(let after): timerDue = now.addingTimeInterval(after)
            case .none: break
            }
        }
        for (a, b) in zip(sends, sends.dropFirst()) { #expect(b.timeIntervalSince(a) >= 1.5 - 0.001) }
        #expect(sends.count >= 12)
        // The trailing timer still holds the newest state
        #expect(c.pending == st("p200"))
    }
}

@MainActor @Suite struct LiveActivityControllerTests {
    private func make(_ backend: FakeBackend, _ clock: ManualClock) -> CoalescingLiveActivityController {
        CoalescingLiveActivityController(backend: backend, now: { clock.now }, schedule: clock.scheduler)
    }

    @Test func startsWithAnEightHourStaleDate() async {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "tiếng Anh", state: st("a"))
        await c.waitUntilIdle()
        #expect(c.isActive)
        #expect(b.calls == [.request(TranslatorActivityStatic(languageCode: "en", languageName: "tiếng Anh"), st("a"),
                                     stale: clock.now.addingTimeInterval(8 * 3600))])
    }

    @Test func notStartedWhenActivitiesAreDisabled() async {
        let b = FakeBackend(), clock = ManualClock()
        b.areActivitiesEnabled = false
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "x", state: st("a"))
        c.update(st("b"))
        await c.waitUntilIdle()
        #expect(!c.isActive)
        #expect(b.calls.isEmpty)
    }

    @Test func aFailedStartLeavesNoActivity() async {
        let b = FakeBackend(), clock = ManualClock()
        b.failRequest = true
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "x", state: st("a"))
        await c.waitUntilIdle()
        #expect(!c.isActive)
        clock.advance(5)
        c.update(st("b"))
        await c.waitUntilIdle()
        #expect(b.updates.isEmpty)
        // The next start tries again
        b.failRequest = false
        c.start(languageCode: "en", languageName: "x", state: st("c"))
        await c.waitUntilIdle()
        #expect(c.isActive)
    }

    @Test func updatesAreCoalescedWithATrailingUpdate() async {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "x", state: st("a"))
        clock.advance(0.2); c.update(st("b"))
        clock.advance(0.2); c.update(st("c"))
        clock.advance(0.2); c.update(st("d"))
        await c.waitUntilIdle()
        #expect(b.updates.isEmpty)
        #expect(clock.pendingTimers == 1)
        clock.advance(0.9)  // t = 1.5
        await c.waitUntilIdle()
        #expect(b.updates == [st("d")])
        clock.advance(10)
        c.update(st("e"))
        await c.waitUntilIdle()
        #expect(b.updates == [st("d"), st("e")])
    }

    @Test func updatesAreTrimmedUnder4KB() async throws {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        let huge = String(repeating: "ữ\u{0301}😀", count: 2000)
        c.start(languageCode: "en", languageName: "x", state: TranslatorActivityState(theirs: huge, translation: huge))
        await c.waitUntilIdle()
        guard case .request(_, let sent, _)? = b.calls.first else { Issue.record("no request"); return }
        #expect(try JSONEncoder().encode(sent).count <= 4096)
        #expect(sent.theirs.utf8.count <= TranslatorActivityState.maxPhraseBytes)
    }

    @Test func endCancelsTheTrailingUpdateAndShowsTheNewestState() async {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "x", state: st("a"))
        clock.advance(0.5); c.update(st("b"))
        c.end()
        clock.advance(5)
        await c.waitUntilIdle()
        #expect(!c.isActive)
        #expect(b.updates.isEmpty)
        #expect(b.calls.last == .end(st("b")))
    }

    @Test func endWithoutAnActivityStillClearsLeftovers() async {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        c.end()
        await c.waitUntilIdle()
        #expect(b.calls == [.end(nil)])
    }

    @Test func startWhileActiveIsAnUpdate() async {
        let b = FakeBackend(), clock = ManualClock()
        let c = make(b, clock)
        c.start(languageCode: "en", languageName: "x", state: st("a"))
        clock.advance(2)
        c.start(languageCode: "en", languageName: "x", state: st("b"))
        await c.waitUntilIdle()
        #expect(b.calls.count == 2)
        #expect(b.updates == [st("b")])
    }
}

@MainActor @Suite struct LiveActivityDriverTests {
    private func snap(_ listening: Bool, _ code: String? = "en", _ t: String = "a") -> LiveActivitySnapshot {
        LiveActivitySnapshot(listening: listening, languageCode: code, languageName: "tiếng Anh", state: st(t))
    }

    @Test func startsUpdatesAndEndsWithListening() {
        let rec = RecordingController()
        let d = LiveActivityDriver(controller: rec)
        d.apply(snap(false))
        #expect(rec.calls.isEmpty)
        d.apply(snap(true))
        d.apply(snap(true, "en", "b"))
        d.apply(snap(false))
        #expect(rec.calls == [.start("en", "tiếng Anh", st("a")), .update(st("b")), .end])
        #expect(d.activeCode == nil)
    }

    @Test func noActivityWithoutALanguage() {
        let rec = RecordingController()
        let d = LiveActivityDriver(controller: rec)
        d.apply(snap(true, nil))
        #expect(rec.calls.isEmpty)
    }

    @Test func aLanguageSwitchRestartsTheActivity() {
        let rec = RecordingController()
        let d = LiveActivityDriver(controller: rec)
        d.apply(snap(true, "en"))
        d.apply(snap(true, "ja"))
        #expect(rec.calls == [.start("en", "tiếng Anh", st("a")), .end, .start("ja", "tiếng Anh", st("a"))])
    }

    @Test func endedFromOutsideStaysEndedUntilTheNextConversation() {
        let rec = RecordingController()
        let d = LiveActivityDriver(controller: rec)
        d.apply(snap(true))
        d.endNow()  // board forgotten
        d.apply(snap(true, "en", "b"))
        #expect(rec.calls == [.start("en", "tiếng Anh", st("a")), .end])
        d.apply(snap(false))
        d.apply(snap(true, "en", "c"))
        #expect(rec.calls.last == .start("en", "tiếng Anh", st("c")))
    }

    @Test func endNowWhileIdleDoesNotBlockTheNextStart() {
        let rec = RecordingController()
        let d = LiveActivityDriver(controller: rec)
        d.apply(snap(false))
        d.endNow()
        d.apply(snap(true))
        #expect(rec.calls == [.end, .start("en", "tiếng Anh", st("a"))])
    }
}

@MainActor @Suite(.serialized) struct LiveActivityWiringTests {
    private func runningUI() -> UIState {
        let ui = UIState()
        ui.languageCode = "en"
        ui.languageLabel = "English"
        ui.board = .ready
        ui.boardBattery = 88
        ui.boardMicOn = true
        ui.lines = [
            UILine(id: "1", mine: false, source: "Hi", target: "Chào", at: Date()),
            UILine(id: "2", mine: true, source: "Tám trăm", target: "800", at: Date()),
            UILine(id: "3", mine: false, source: "???", target: "Không nghe rõ", unclear: true, at: Date()),
        ]
        return ui
    }

    @Test func snapshotTakesTheirLatestClearPhrase() {
        let ui = runningUI()
        ui.listening = true
        let s = LiveActivitySnapshot.of(ui)
        #expect(s.listening)
        #expect(s.languageCode == "en")
        #expect(s.languageName == "tiếng Anh")
        #expect(s.state == TranslatorActivityState(listening: true, boardBattery: 88, theirs: "Hi", translation: "Chào",
                                                   micOn: true))
        ui.board = .off
        #expect(LiveActivitySnapshot.of(ui).state.boardBattery == nil)
    }

    @Test func languageNamesAndShortCodes() {
        #expect(TranslatorActivityStatic.vietnameseName("ja", label: "日本語") == "tiếng Nhật")
        #expect(TranslatorActivityStatic.vietnameseName("zh-Hans", label: "中文") == "tiếng Trung")
        #expect(TranslatorActivityStatic.vietnameseName("xx", label: "Xish") == "Xish")
        #expect(TranslatorActivityStatic(languageCode: "zh-Hans", languageName: "").shortCode == "ZH")
        #expect(TranslatorActivityStatic(languageCode: "en", languageName: "").shortCode == "EN")
    }

    @Test func observerFollowsTheScreenModel() async {
        let ui = runningUI()
        let rec = RecordingController()
        let observer = LiveActivityObserver(ui: ui, driver: LiveActivityDriver(controller: rec))
        #expect(rec.calls.isEmpty)
        ui.listening = true
        await settle()
        #expect(rec.calls.first.map { if case .start("en", "tiếng Anh", _) = $0 { true } else { false } } == true)
        ui.boardMicOn = false
        await settle()
        #expect(rec.calls.last == .update(TranslatorActivityState(listening: true, boardBattery: 88, theirs: "Hi",
                                                                  translation: "Chào", micOn: false)))
        ui.listening = false
        await settle()
        #expect(rec.calls.last == .end)
        observer.cancel()
    }

    @Test func buttonsReachTheAppThroughTheBridge() async {
        IntentBridge.reset()
        defer { IntentBridge.reset() }
        let ui = runningUI()
        var startStops = 0, toggles = 0
        ui.startStop = { startStops += 1; ui.listening.toggle() }
        ui.toggleBoardMic = { toggles += 1 }
        let rec = RecordingController()
        let driver = LiveActivityDriver(controller: rec)

        // An intent that arrives before the app installed its handler is replayed
        IntentBridge.perform(.toggleBoardMic)
        #expect(IntentBridge.pending == [.toggleBoardMic])
        IntentBridge.install { LiveActivityActions.handle($0, ui: ui, driver: driver) }
        #expect(toggles == 1)
        #expect(IntentBridge.pending.isEmpty)

        ui.listening = true
        driver.apply(LiveActivitySnapshot.of(ui))
        IntentBridge.perform(.stop)
        #expect(startStops == 1)
        #expect(!ui.listening)
        #expect(rec.calls.last == .end)
        // Stop with nothing listening: no start/stop toggle, but leftovers are still ended
        IntentBridge.perform(.stop)
        #expect(startStops == 1)
        #expect(rec.calls.filter { $0 == .end }.count == 2)
    }

    @Test func demoFlag() {
        #expect(LiveActivityDemo.requested(["app", "-demo", "lockactivity"]))
        #expect(LiveActivityDemo.requested(["app", "--demo", "LockActivity"]))
        #expect(!LiveActivityDemo.requested(["app", "-demo", "lock"]))
        #expect(!LiveActivityDemo.requested(["app", "-demo"]))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}
