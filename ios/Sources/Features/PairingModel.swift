import Foundation
import Observation

/// The app side of pairing by code (ARCHITECTURE §4). After its setup the link reads the protected control
/// characteristic (`…0004`). New firmware answers "insufficient authentication", iOS shows its system dialog with
/// the 6 digits the board shows, and the read succeeds once both sides confirmed. Old firmware asks for no pairing:
/// the read just succeeds. Either way the board is pinned only after that read succeeded. The app never shows a
/// code of its own.
enum PairingState: Hashable, Sendable {
    case idle
    /// Looking for a board (or waiting for Bluetooth to come on).
    case scanning
    /// Connected to a board, setting up; `battery` in percent when known.
    case found(name: String, battery: Int?)
    /// The protected read is out: compare the board's code with the iPhone dialog and confirm on both.
    case confirming(name: String, battery: Int?)
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
}

/// What the board link reports about pairing (`ESPLink.onPairingEvent`, on its BLE queue).
enum PairingLinkEvent: Hashable, Sendable {
    /// Scanning, or a pending connect to the pinned board.
    case scanning
    /// Connected and discovering the board's characteristics.
    case connected(name: String)
    /// The first protected access (read of `…0004`) is out; new firmware asks for the code now.
    case authenticating
    /// The protected read succeeded (paired, or old firmware): the board is pinned and set up.
    case authenticated
    case authFailed(PairingFailure)
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
            case .confirming: state = .failed(.lost)
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
            if case .paired = state { return }
            state = .failed(reason)
        case .linkLost:
            switch state {
            case .confirming: state = .failed(.lost)
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
}

/// The BLE-backed pairing model: link events (any thread) feed a `PairingMachine` on the main actor; a timer turns
/// a confirmation nobody answers into a timeout.
@Observable @MainActor
final class LinkPairingModel: PairingModeling {
    private(set) var machine = PairingMachine()
    var state: PairingState { machine.state }

    @ObservationIgnored private let retryLink: @MainActor () -> Bool
    @ObservationIgnored private let onStart: @MainActor () -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let timeout: TimeInterval

    /// `retryLink` asks the link to read again; true when it is connected (the read goes out at once). `onStart`
    /// runs when the Pair screen appears (the link creates its central if the Permissions step did not).
    init(retryLink: @escaping @MainActor () -> Bool, onStart: @escaping @MainActor () -> Void = {},
         timeout: TimeInterval = PairingMachine.confirmTimeout) {
        self.retryLink = retryLink
        self.onStart = onStart
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
