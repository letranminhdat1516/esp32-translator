import AVFAudio
import Foundation
import Speech

/// What the engine needs from a speech recognizer (LiveTranscriber; fakes in tests)
protocol Recognizer: AnyObject, Sendable {
    var locale: Locale { get }
    var audioFormat: AVAudioFormat? { get }
    var assetStatus: AssetInventory.Status { get async }
    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws
    func setHints(_ hints: [String]) async
    func feed(_ buffer: AVAudioPCMBuffer)
    func finalizeNow()
    func stop() async
}

extension LiveTranscriber: Recognizer {}

/// The two recognizers of a pair: the board's language X (results to `onTheirs`) and home (results to
/// `onMine`). `start` awaits many times (permission, locale lookup, assets, model loading); a `stop` or another
/// `start` may run in between. Every start gets a token: after each await a start whose token is no longer
/// current stops what it built and throws `notReady`, and the event callbacks of a superseded or stopped pair
/// emit nothing, even before its recognizers have finished stopping.
@MainActor
final class RecognizerPair {
    typealias Factory = @MainActor (_ language: String) async -> (any Recognizer)?

    private(set) var pair: PairMsg?
    private(set) var theirs: (any Recognizer)?
    private(set) var mine: (any Recognizer)?

    private let events: EventQueue
    private let factory: Factory
    private let beforeStart: @MainActor () async -> Void
    /// The pair's generation, read by the board recognizer's result task
    private let generation = Generation()
    /// Current start; bumped by every start and stop
    private var token = 0
    /// Lets the running pair's callbacks through; switched off when it is stopped or superseded
    private var live = Live()

    /// `beforeStart` runs at the beginning of a fresh start (the app asks for the mic permission there)
    init(events: EventQueue, factory: @escaping Factory = { await LiveTranscriber.resolve($0) },
         beforeStart: @escaping @MainActor () async -> Void = {}) {
        self.events = events
        self.factory = factory
        self.beforeStart = beforeStart
    }

    /// Builds and starts both recognizers. Returns false when the same languages were already running (only the
    /// generation and hints changed), true for a fresh start. Throws `notReady` when a recognizer is missing,
    /// fails, or a later `start`/`stop` overtook this one.
    func start(_ pair: PairMsg, hints: [String]) async throws -> Bool {
        if let running = self.pair, running.home == pair.home, running.other == pair.other, let x = theirs {
            self.pair = pair
            generation.value = pair.generation
            await x.setHints(hints)
            return false
        }
        stop()
        let mine = token
        var built: [any Recognizer] = []
        /// After every await: a start or stop came in meanwhile
        func checkCurrent() async throws {
            guard token != mine else { return }
            for r in built { await r.stop() }
            throw EngineErrors.notReady("start of \(pair.other)/\(pair.home) was overtaken by a later start or stop")
        }

        await beforeStart()
        try await checkCurrent()
        guard let x = await factory(pair.other) else {
            try await checkCurrent()
            throw EngineErrors.notReady("no on-device recognizer for \(pair.other)")
        }
        try await checkCurrent()
        guard let home = await factory(pair.home) else {
            try await checkCurrent()
            throw EngineErrors.notReady("no on-device recognizer for \(pair.home)")
        }
        try await checkCurrent()
        for r in [x, home] {
            let status = await r.assetStatus
            try await checkCurrent()
            if status != .installed {
                throw EngineErrors.notReady("speech model for \(r.locale.identifier) is not installed")
            }
        }

        generation.value = pair.generation
        let live = Live()
        self.live = live
        let events = self.events, generation = self.generation
        do {
            built.append(x)
            try await x.start { event in
                guard live.on, let msg = EngineMapping.theirs(event, generation: generation.value) else { return }
                events.send(.theirs(msg))
            }
            try await checkCurrent()
            built.append(home)
            try await home.start { event in
                guard live.on else { return }
                events.send(.mine(EngineMapping.mine(event, now: Date())))
            }
            try await checkCurrent()
            guard x.audioFormat != nil, home.audioFormat != nil else {
                throw EngineErrors.notReady("no audio format for the speech models")
            }
            await x.setHints(hints)
            try await checkCurrent()
        } catch {
            live.on = false
            if token == mine { for r in built { await r.stop() } }
            if let error = error as? PigeonError { throw error }
            throw EngineErrors.notReady("recognizers did not start: \(error.localizedDescription)")
        }
        self.pair = pair
        theirs = x
        self.mine = home
        return true
    }

    /// Silences and stops the running pair and makes any start in progress give up. Idempotent.
    func stop() {
        token += 1
        live.on = false
        let running = [theirs, mine].compactMap { $0 }
        theirs = nil
        mine = nil
        pair = nil
        if !running.isEmpty { Task { for r in running { await r.stop() } } }
    }

    var isRunning: Bool { theirs != nil }
}

/// A switch read from the recognizers' result tasks
final class Live: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The current pair generation, written on the main actor and read from the recognizer's result task
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int64 = 0

    var value: Int64 {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
