import Foundation
import Observation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// The conversation's Live Activity (ARCHITECTURE §6, budget §1: ≤ 1 update per 1.5 s, ≤ 4 KB).
//
//   UIState ──(observation)──▶ LiveActivityObserver ─▶ LiveActivityDriver ─▶ LiveActivityControlling
//                                                     (start / update / end)   CoalescingLiveActivityController
//                                                                                └▶ LiveActivityBackend (ActivityKit)
//   Live Activity buttons ─▶ IntentBridge ─▶ LiveActivityActions ─▶ UIState intents + driver
//
// Everything above the ActivityKit backend is plain logic with an injected clock and scheduler, tested on the Mac.

/// Starts, updates and ends the Live Activity.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func start(languageCode: String, languageName: String, state: TranslatorActivityState)
    func update(_ state: TranslatorActivityState)
    func end()
}

/// Does nothing (demo mode, tests, devices without Live Activities).
@MainActor
final class NoopLiveActivityController: LiveActivityControlling {
    private(set) var lastState: TranslatorActivityState?
    init() {}
    func start(languageCode: String, languageName: String, state: TranslatorActivityState) { lastState = state }
    func update(_ state: TranslatorActivityState) { lastState = state }
    func end() { lastState = nil }
}

// MARK: - Coalescing

/// Rate limit for activity updates: at most one per `interval`, always the latest state, with a trailing update so
/// the last change is never lost. Pure value type; time comes in with each call.
struct LiveActivityCoalescer: Sendable {
    enum Decision: Equatable, Sendable {
        /// Send this state now.
        case send(TranslatorActivityState)
        /// Call `fire(at:)` after this many seconds.
        case schedule(after: TimeInterval)
        /// Nothing to do.
        case none
    }

    let interval: TimeInterval
    private(set) var lastSent: TranslatorActivityState?
    private(set) var lastSentAt: Date?
    /// The newest state not sent yet (sent by the trailing `fire`).
    private(set) var pending: TranslatorActivityState?
    /// A trailing `fire` is scheduled.
    private(set) var timerArmed = false

    init(interval: TimeInterval = 1.5) { self.interval = interval }

    /// The activity was just started with `state` (the request carries it: counts as a send).
    mutating func started(with state: TranslatorActivityState, at now: Date) {
        lastSent = state
        lastSentAt = now
        pending = nil
    }

    mutating func offer(_ state: TranslatorActivityState, at now: Date) -> Decision {
        if state == lastSent {
            // Back to what is showing: a pending change is moot (an armed timer then finds nothing to send)
            pending = nil
            return .none
        }
        if timerArmed {
            pending = state
            return .none
        }
        if let wait = remaining(at: now) {
            pending = state
            timerArmed = true
            return .schedule(after: wait)
        }
        lastSent = state
        lastSentAt = now
        return .send(state)
    }

    /// The trailing timer fired.
    mutating func fire(at now: Date) -> Decision {
        timerArmed = false
        guard let state = pending else { return .none }
        if let wait = remaining(at: now) {
            timerArmed = true
            return .schedule(after: wait)
        }
        pending = nil
        lastSent = state
        lastSentAt = now
        return .send(state)
    }

    mutating func reset() {
        lastSent = nil
        lastSentAt = nil
        pending = nil
        timerArmed = false
    }

    /// Seconds left before another send is allowed; nil when one is allowed now (1 ms tolerance for timers).
    private func remaining(at now: Date) -> TimeInterval? {
        guard let lastSentAt else { return nil }
        let left = interval - now.timeIntervalSince(lastSentAt)
        return left > 0.001 ? left : nil
    }
}

// MARK: - Controller

/// The platform side: one Live Activity of `TranslatorActivityAttributes`.
@MainActor
protocol LiveActivityBackend: AnyObject {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled` (the user can turn Live Activities off per app).
    var areActivitiesEnabled: Bool { get }
    func request(_ info: TranslatorActivityStatic, _ state: TranslatorActivityState, staleDate: Date) async throws
    func update(_ state: TranslatorActivityState, staleDate: Date) async
    /// Ends every activity of the app (leftovers from an earlier run too), showing `state` if given.
    func end(_ state: TranslatorActivityState?) async
}

/// `LiveActivityControlling` over a backend: checks the authorization, coalesces updates (`LiveActivityCoalescer`),
/// runs the backend calls one after another in the order asked, and treats a failed start as "no activity".
@MainActor
final class CoalescingLiveActivityController: LiveActivityControlling {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Stale after 8 h: a conversation left running all day shows as outdated rather than live.
    nonisolated static let defaultStaleAfter: TimeInterval = 8 * 3600

    private let backend: any LiveActivityBackend
    private let now: () -> Date
    private let schedule: Scheduler
    let staleAfter: TimeInterval
    private var coalescer: LiveActivityCoalescer
    private(set) var isActive = false
    /// Bumped on every start and end: timers and failures of an earlier activity are ignored.
    private var generation = 0
    private var chain: Task<Void, Never>?

    init(backend: any LiveActivityBackend, interval: TimeInterval = 1.5,
         staleAfter: TimeInterval = CoalescingLiveActivityController.defaultStaleAfter,
         now: @escaping () -> Date = { Date() },
         schedule: Scheduler? = nil) {
        self.backend = backend
        self.now = now
        self.staleAfter = staleAfter
        self.schedule = schedule ?? { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                work()
            }
        }
        coalescer = LiveActivityCoalescer(interval: interval)
    }

    func start(languageCode: String, languageName: String, state: TranslatorActivityState) {
        let state = state.trimmed()
        if isActive {
            update(state)
            return
        }
        guard backend.areActivitiesEnabled else {
            Diag.log("live activity: disabled in Settings, not started")
            return
        }
        isActive = true
        generation += 1
        let gen = generation
        let t = now()
        coalescer.reset()
        coalescer.started(with: state, at: t)
        let info = TranslatorActivityStatic(languageCode: languageCode, languageName: languageName)
        let stale = t.addingTimeInterval(staleAfter)
        enqueue { [weak self] backend in
            do {
                try await backend.request(info, state, staleDate: stale)
            } catch {
                Diag.log("live activity: not started (\(error))")
                self?.startFailed(gen)
            }
        }
    }

    func update(_ state: TranslatorActivityState) {
        guard isActive else { return }
        handle(coalescer.offer(state.trimmed(), at: now()))
    }

    /// Ends the activity (and any left from an earlier run), showing the newest state for the dismissal.
    func end() {
        let final = isActive ? (coalescer.pending ?? coalescer.lastSent) : nil
        isActive = false
        generation += 1
        coalescer.reset()
        enqueue { backend in await backend.end(final) }
    }

    /// Waits until every backend call asked so far has finished (tests).
    func waitUntilIdle() async {
        var last: Task<Void, Never>?
        repeat {
            last = chain
            await last?.value
        } while chain != last
    }

    private func handle(_ decision: LiveActivityCoalescer.Decision) {
        switch decision {
        case .send(let state):
            let stale = now().addingTimeInterval(staleAfter)
            enqueue { backend in await backend.update(state, staleDate: stale) }
        case .schedule(let after):
            let gen = generation
            schedule(after) { [weak self] in self?.fire(gen) }
        case .none:
            break
        }
    }

    private func fire(_ gen: Int) {
        guard gen == generation, isActive else { return }
        handle(coalescer.fire(at: now()))
    }

    private func startFailed(_ gen: Int) {
        guard gen == generation else { return }
        isActive = false
        coalescer.reset()
    }

    private func enqueue(_ work: @escaping @MainActor (any LiveActivityBackend) async -> Void) {
        let previous = chain, backend = self.backend
        chain = Task { @MainActor in
            await previous?.value
            await work(backend)
        }
    }
}

// MARK: - From the screen model

/// What the activity needs from `UIState`.
struct LiveActivitySnapshot: Equatable, Sendable {
    var listening: Bool
    var languageCode: String?
    var languageName: String
    var state: TranslatorActivityState

    @MainActor
    static func of(_ ui: UIState) -> LiveActivitySnapshot {
        // Their latest phrase and its translation; "Không nghe rõ" lines are skipped
        let last = ui.lines.last { !$0.mine && !$0.unclear }
        let code = ui.languageCode
        return LiveActivitySnapshot(
            listening: ui.listening,
            languageCode: code,
            languageName: code.map { TranslatorActivityStatic.vietnameseName($0, label: ui.languageLabel) } ?? ui.languageLabel,
            state: TranslatorActivityState(listening: ui.listening, boardBattery: ui.board == .ready ? ui.boardBattery : nil,
                                           theirs: last?.source ?? "", translation: last?.target ?? "",
                                           micOn: ui.boardMicOn))
    }
}

/// Turns screen-model snapshots into start / update / end: an activity runs while a conversation is listening.
@MainActor
final class LiveActivityDriver {
    private let controller: any LiveActivityControlling
    /// The language of the running activity; nil when none runs.
    private(set) var activeCode: String?
    /// Ended from outside (stop button, board forgotten) while still listening: no restart until listening stops.
    private(set) var suppressed = false
    private var lastListening = false

    init(controller: any LiveActivityControlling) { self.controller = controller }

    func apply(_ s: LiveActivitySnapshot) {
        lastListening = s.listening
        guard s.listening, let code = s.languageCode else {
            suppressed = false
            if activeCode != nil {
                activeCode = nil
                controller.end()
            }
            return
        }
        guard !suppressed else { return }
        if activeCode == code {
            controller.update(s.state)
            return
        }
        // A language switch: the static part changes, so a new activity
        if activeCode != nil { controller.end() }
        activeCode = code
        controller.start(languageCode: code, languageName: s.languageName, state: s.state)
    }

    /// Ends the activity now (the stop button, the board forgotten, app shutdown); it comes back with the next
    /// conversation.
    func endNow() {
        activeCode = nil
        suppressed = lastListening
        controller.end()
    }
}

/// Re-reads the snapshot whenever a field it uses changes (Observation) and hands it to the driver.
@MainActor
final class LiveActivityObserver {
    private let ui: UIState
    let driver: LiveActivityDriver
    private var cancelled = false

    init(ui: UIState, driver: LiveActivityDriver) {
        self.ui = ui
        self.driver = driver
        observe()
    }

    func cancel() { cancelled = true }

    private func observe() {
        guard !cancelled else { return }
        let snapshot = withObservationTracking {
            LiveActivitySnapshot.of(ui)
        } onChange: { [weak self] in
            // Called before the change lands: read again on the next main-actor turn
            Task { @MainActor in self?.observe() }
        }
        driver.apply(snapshot)
    }
}

/// What the Live Activity buttons do in the app (`IntentBridge.install`).
@MainActor
enum LiveActivityActions {
    static func handle(_ action: LiveActivityAction, ui: UIState, driver: LiveActivityDriver) {
        switch action {
        case .stop:
            if ui.listening { ui.startStop() }
            // Also when nothing is listening: a leftover activity (an earlier run) must go away on "Dừng"
            driver.endNow()
        case .toggleBoardMic:
            // The observer sends the new micOn with the next update
            ui.toggleBoardMic()
        }
    }
}

/// `-demo lockactivity`: demo mode on the Live screen plus a real Live Activity (simulator screenshots).
enum LiveActivityDemo {
    static let screen = "lockactivity"

    static func requested(_ arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(where: { $0 == "-demo" || $0 == "--demo" }), i + 1 < arguments.count else {
            return false
        }
        return arguments[i + 1].lowercased() == screen
    }
}

// MARK: - ActivityKit

#if canImport(ActivityKit) && os(iOS)
/// The real backend. One activity at a time; `end` and a new `request` also end leftovers (a crash or a kill
/// leaves the activity on the lock screen until it is stale).
@MainActor
final class ActivityKitLiveActivityBackend: LiveActivityBackend {
    private var activity: Activity<TranslatorActivityAttributes>?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(_ info: TranslatorActivityStatic, _ state: TranslatorActivityState, staleDate: Date) async throws {
        await end(nil)
        activity = try Activity.request(attributes: TranslatorActivityAttributes(info),
                                        content: ActivityContent(state: state, staleDate: staleDate),
                                        pushType: nil)
        Diag.log("live activity: started \(activity?.id ?? "?")")
    }

    func update(_ state: TranslatorActivityState, staleDate: Date) async {
        guard let activity, activity.activityState == .active else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(_ state: TranslatorActivityState?) async {
        activity = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        for a in Activity<TranslatorActivityAttributes>.activities {
            await a.end(content, dismissalPolicy: .immediate)
        }
    }

    /// App termination: ends every activity before the process goes, waiting at most `timeout`.
    nonisolated static func endAllBlocking(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<TranslatorActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// The app's wiring: the real controller and the termination hook.
@MainActor
enum LiveActivitySetup {
    static func makeController() -> CoalescingLiveActivityController {
        CoalescingLiveActivityController(backend: ActivityKitLiveActivityBackend())
    }

    /// Ends the activity when the app is terminated (the swipe-up kill sends `willTerminate` to a running app).
    static func installTerminationHook() {
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            ActivityKitLiveActivityBackend.endAllBlocking()
        }
    }
}
#endif
