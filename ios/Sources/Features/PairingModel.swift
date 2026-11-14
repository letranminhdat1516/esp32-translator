import Foundation
import Observation

/// The app side of pairing by code (ARCHITECTURE §4). After its setup the link reads the protected control
/// characteristic (`…0004`). New firmware answers "insufficient authentication", iOS shows its system dialog with
/// the 6 digits the board shows, and the read succeeds once both sides confirmed. A board whose info reports version
/// ≥ 2 (pairing by code enforced) is pinned only after that read succeeded. Old firmware (version < 2, or no control
/// characteristic) asks for no pairing, so its read proves nothing: the link holds it and the screen asks the user
/// (`legacyConsent`); only "Vẫn ghép" pins it. The app never shows a code of its own.
enum PairingState: Hashable, Sendable {
    case idle
    /// Looking for a board (or waiting for Bluetooth to come on).
    case scanning
    /// Connected to a board, setting up; `battery` in percent when known.
    case found(name: String, battery: Int?)
    /// The protected read is out: compare the board's code with the iPhone dialog and confirm on both.
    case confirming(name: String, battery: Int?)
    /// An old-firmware board that cannot authenticate: pin it only if the user says it is theirs. `id`/`gen` name the
    /// peripheral and link the question was asked on; the answer goes back with them (`ESPLink.answerLegacyBoard`).
    case legacyConsent(name: String, id: UUID, gen: Int)
    case paired(name: String)
    case failed(PairingFailure)
}

/// Why pairing did not finish.
enum PairingFailure: Hashable, Sendable {
    /// "Sai" on the board, "Huỷ" on the iPhone, or the board refused (locked, too many attempts).
    case rejected
    /// Nobody answered in time (the board gives up after 30 s).
    case timeout
    /// The board went away while pairing.
    case lost
    /// Bluetooth is off or not allowed.
    case bluetoothOff
    /// The user cancelled pinning an old-firmware board ("Huỷ").
    case declined
    /// The pinned (secure) board no longer authenticates: it reports old firmware or lacks the protected
    /// characteristic. The link refused it and never downgrades the pin.
    case unverified
}

/// What the board link reports about pairing (`ESPLink.onPairingEvent`, on its BLE queue).
enum PairingLinkEvent: Hashable, Sendable {
    /// Scanning, or a pending connect to the pinned board.
    case scanning
    /// Connected and discovering the board's characteristics.
    case connected(name: String)
    /// The first protected access (read of `…0004`) is out; new firmware asks for the code now.
    case authenticating
    /// The board is set up: paired (pinned secure), accepted by the user (pinned legacy), or the pinned board back.
    case authenticated
    case authFailed(PairingFailure)
    /// The board cannot authenticate (old firmware): the link waits for the user's answer about peripheral `id` on
    /// link generation `gen` (`ESPLink.answerLegacyBoard(id:gen:accept:)`).
    case legacyBoard(id: UUID, gen: Int)
    /// The link dropped.
    case linkLost
    case bluetoothOff
}

/// The pure pairing state machine: events from the link and from the user in, a state out.
struct PairingMachine: Hashable, Sendable {
    /// No answer from the user within this many seconds of the dialog counts as a timeout (the board's own limit
    /// is 30 s; a little slack for the radio).
    static let confirmTimeout: TimeInterval = 40

    private(set) var state: PairingState = .idle
    /// The board's name and battery, kept across `found` → `confirming`.
    private var name: String?
    private var battery: Int?

    init(state: PairingState = .idle) { self.state = state }

    mutating func handle(_ event: PairingLinkEvent) {
        switch event {
        case .scanning:
            // A failure stays on screen until the user retries; a pinned board reconnecting after pairing stays paired
            switch state {
            case .failed, .paired: return
            case .confirming, .legacyConsent: state = .failed(.lost)
            default: state = .scanning
            }
        case let .connected(n):
            name = n
            if case .failed = state { return }
            if case .paired = state { return }
            state = .found(name: n, battery: battery)
        case .authenticating:
            if case .failed = state { return }
            state = .confirming(name: name ?? Self.defaultName, battery: battery)
        case .authenticated:
            state = .paired(name: name ?? Self.defaultName)
        case let .authFailed(reason):
            // A paired board that no longer authenticates is shown; other refusals of a paired board are retried
            // by the link on its own
            if case .paired = state, reason != .unverified { return }
            state = .failed(reason)
        case let .legacyBoard(id, gen):
            if case .failed = state { return }
            state = .legacyConsent(name: name ?? Self.defaultName, id: id, gen: gen)
        case .linkLost:
            switch state {
            case .confirming, .legacyConsent: state = .failed(.lost)
            case .found: state = .scanning
            default: break
            }
        case .bluetoothOff:
            if case .paired = state { return }
            state = .failed(.bluetoothOff)
        }
    }

    /// The board info told the battery (not sent by the current firmware; kept for when it is).
    mutating func battery(_ percent: Int?) {
        battery = percent
        switch state {
        case let .found(n, _): state = .found(name: n, battery: percent)
        case let .confirming(n, _): state = .confirming(name: n, battery: percent)
        default: break
        }
    }

    /// The user started pairing (the Pair screen appeared).
    mutating func start() {
        if state == .idle { state = .scanning }
    }

    /// "Thử lại" after a failure: the link reads again (still connected) or keeps scanning.
    mutating func retry(connected: Bool) {
        guard case .failed = state else { return }
        if connected, let name {
            state = .confirming(name: name, battery: battery)
        } else {
            state = .scanning
        }
    }

    /// "Vẫn ghép": the link finishes the setup and reports `authenticated`.
    mutating func acceptLegacy() {
        guard case let .legacyConsent(n, _, _) = state else { return }
        state = .found(name: n, battery: battery)
    }

    /// "Huỷ": the link drops that board; "Thử lại" looks again.
    mutating func declineLegacy() {
        guard case .legacyConsent = state else { return }
        state = .failed(.declined)
    }

    /// The confirm timer fired; only a pending confirmation times out.
    mutating func timedOut() {
        if case .confirming = state { state = .failed(.timeout) }
    }

    static let defaultName = "ESP-Translator"
}

@MainActor
protocol PairingModeling: AnyObject {
    var state: PairingState { get }
    /// The Pair screen appeared.
    func start()
    /// "Thử lại" after a failure.
    func retry()
    /// "Vẫn ghép" on the old-firmware warning.
    func acceptLegacy()
    /// "Huỷ" on the old-firmware warning.
    func declineLegacy()
}

/// A scripted pairing model: demo mode and tests.
@Observable @MainActor
final class FakePairingModel: PairingModeling {
    var state: PairingState
    private(set) var retries = 0

    init(state: PairingState = .idle) { self.state = state }

    func start() { if state == .idle { state = .scanning } }

    func retry() {
        retries += 1
        state = .scanning
    }

    func acceptLegacy() {
        if case let .legacyConsent(n, _, _) = state { state = .paired(name: n) }
    }

    func declineLegacy() {
        if case .legacyConsent = state { state = .failed(.declined) }
    }
}

/// The BLE-backed pairing model: link events (any thread) feed a `PairingMachine` on the main actor; a timer turns
/// a confirmation nobody answers into a timeout.
@Observable @MainActor
final class LinkPairingModel: PairingModeling {
    private(set) var machine = PairingMachine()
    var state: PairingState { machine.state }

    @ObservationIgnored private let retryLink: @MainActor () -> Bool
    @ObservationIgnored private let onStart: @MainActor () -> Void
    @ObservationIgnored private let consent: @MainActor (_ id: UUID, _ gen: Int, _ accept: Bool) -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let timeout: TimeInterval

    /// `retryLink` asks the link to read again; true when it is connected (the read goes out at once). `onStart`
    /// runs when the Pair screen appears (the link creates its central if the Permissions step did not). `consent`
    /// gives the link the user's answer about an old-firmware board (true: "Vẫn ghép") with the peripheral and link
    /// generation it was asked on, so the link drops an answer that arrives after a reconnect.
    init(retryLink: @escaping @MainActor () -> Bool, onStart: @escaping @MainActor () -> Void = {},
         consent: @escaping @MainActor (_ id: UUID, _ gen: Int, _ accept: Bool) -> Void = { _, _, _ in },
         timeout: TimeInterval = PairingMachine.confirmTimeout) {
        self.retryLink = retryLink
        self.onStart = onStart
        self.consent = consent
        self.timeout = timeout
    }

    /// Already paired before this run (a pinned board): the screen shows paired.
    func markPaired(name: String) { machine = PairingMachine(state: .paired(name: name)) }

    /// The board was forgotten: pairing starts over.
    func reset() {
        timer?.cancel()
        timer = nil
        machine = PairingMachine()
    }

    func handle(_ event: PairingLinkEvent) {
        machine.handle(event)
        armTimer()
    }

    func start() {
        onStart()
        machine.start()
    }

    func retry() {
        machine.retry(connected: retryLink())
        armTimer()
    }

    func acceptLegacy() {
        guard case let .legacyConsent(_, id, gen) = machine.state else { return }
        machine.acceptLegacy()
        consent(id, gen, true)
    }

    func declineLegacy() {
        guard case let .legacyConsent(_, id, gen) = machine.state else { return }
        machine.declineLegacy()
        consent(id, gen, false)
    }

    private func armTimer() {
        guard case .confirming = machine.state else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let seconds = timeout
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.machine.timedOut()
        }
    }
}
