import Foundation

// ESPLink's bookkeeping, apart from CoreBluetooth so it runs under `swift test` on the Mac. Behaviour of
// app/lib/board/ble_board_link.dart: the generation-guarded text queue, the label resent on ready, the reconnect
// backoff. ESPLink owns one of each and uses them on its BLE queue only.

/// Subtitle chunks not yet written to the text characteristic (`Target`, a CBCharacteristic in the app).
/// A new text replaces the unsent one. Every new characteristic (connect, services reset) or loss of it bumps
/// `generation` and drops the queue; a write failure counts only when it happened on the current characteristic,
/// so a stale write failing after a reset never clears the new link's queue (Review Focus 1).
struct BoardWriteQueue<Target: AnyObject> {
    private(set) var generation = 0
    private(set) var target: Target?
    private var pending: [Data] = []
    /// False while the link is being set up: chunks are kept but not written until `markReady`
    private(set) var ready = false

    var pendingCount: Int { pending.count }

    /// The link has a (new) text characteristic; `ready: false` while the clock and label still have to go first
    mutating func attach(_ target: Target, ready: Bool = true) {
        generation += 1
        self.target = target
        self.ready = ready
        pending.removeAll()
    }

    /// Setup is done: queued chunks may be written
    mutating func markReady() { ready = true }

    /// The characteristic is gone (drop, Bluetooth off, services reset)
    mutating func detach() {
        generation += 1
        target = nil
        ready = false
        pending.removeAll()
    }

    /// Replaces the unsent chunks; false (nothing queued) when there is no characteristic
    mutating func replace(_ chunks: [Data]) -> Bool {
        guard target != nil else { return false }
        pending = chunks
        return true
    }

    /// Writes chunks in order while `canSend` (CoreBluetooth's write-without-response flow control)
    mutating func drain(canSend: () -> Bool, write: (Target, Data) -> Void) {
        guard let target, ready else { return }
        while !pending.isEmpty && canSend() {
            write(target, pending.removeFirst())
        }
    }

    /// A write on `characteristic` failed: the board's text buffer is in an unknown state, so the rest of that
    /// text is dropped. Ignored for a characteristic of an earlier generation.
    mutating func writeFailed(on characteristic: Target) {
        guard characteristic === target else { return }
        pending.removeAll()
    }
}

/// The object (the translator service) whose setup is in progress. Callbacks for any other object (a discovery
/// that started before a services reset or a drop) are ignored, so dead characteristics are never set up.
struct SetupGuard<Object: AnyObject> {
    private(set) var current: Object?

    mutating func begin(_ object: Object) { current = object }
    mutating func reset() { current = nil }
    func isCurrent(_ object: Object) -> Bool { object === current }
}

/// Pause before rescanning after a drop or a failed connect: the first rescan is immediate, then `base`, doubling
/// per consecutive failure up to `max`; `reset` when the link is ready or Bluetooth comes on.
struct ReconnectBackoff {
    let base: TimeInterval
    let max: TimeInterval
    private var failures = 0

    init(base: TimeInterval = 0.5, max: TimeInterval = 10) {
        self.base = base
        self.max = max
    }

    mutating func nextDelay() -> TimeInterval {
        defer { failures += 1 }
        guard failures > 0 else { return 0 }
        var delay = base
        for _ in 1..<failures where delay < max { delay *= 2 }
        return min(delay, max)
    }

    mutating func reset() { failures = 0 }
}

/// The other language's label (kind 3): sent only to a board that has the `…0005` board-info characteristic
/// (older firmware shows unknown kinds as subtitles), remembered and resent after the clock whenever the link
/// becomes ready, since the board forgets it on a reconnect.
struct BoardLabel {
    private(set) var last: String?
    private(set) var supported = false

    /// Remembers `label`; the text to frame and send now (cut to `BoardProtocol.maxLabelBytes`), nil when this
    /// board does not take labels
    mutating func send(_ label: String) -> String? {
        last = label
        return supported ? BoardProtocol.labelText(label) : nil
    }

    /// Whether the board info of the current link was read and parsed
    mutating func boardInfo(parsed: Bool) { supported = parsed }

    /// The link is gone: the next board may be older firmware, so no label goes out until its info is read.
    /// The label itself is kept for the resend on ready.
    mutating func linkGone() { supported = false }

    /// Text-characteristic writes when the link becomes ready (each written with response): the clock, then the
    /// remembered label if the board takes labels
    func readyFrames(maxWrite: Int, at date: Date = Date(), in timeZone: TimeZone = .current) -> [Data] {
        var frames = [BoardProtocol.timeFrame(at: date, in: timeZone)]
        if supported, let last {
            frames += BoardProtocol.frameText(BoardProtocol.labelText(last), kind: .label, maxWrite: maxWrite)
        }
        return frames
    }

    /// What the board can render, from the `…0005` value; `latinVI` when it is absent or unreadable
    static func info(from value: Data?) -> BoardInfo {
        value.flatMap(BoardProtocol.parseBoardInfo) ?? BoardInfo(protocolVersion: 0, fontSets: .latinVI)
    }
}

/// Which board this phone talks to (P9 access control). The first board is trusted on first use: once its
/// translator setup finished AND an encrypted access succeeded on the same link (the board's Claude characteristics
/// need a bonded, encrypted link), its identifier is pinned. From then on only that board is reconnected, by
/// identifier (`retrievePeripherals(withIdentifiers:)` + a pending connect); a device found by a scan that is not
/// the pinned board is never connected, whatever it advertises. Claude traffic from the board is forwarded only on
/// a link where the encrypted access succeeded. `forget` drops the pin (a new board) and scanning starts again.
struct BoardPin {
    enum Reconnect: Equatable {
        /// Connect to this identifier only (and wait for it)
        case pinned(UUID)
        /// No board yet: scan for the board service
        case discover
    }

    private(set) var pinned: UUID?
    /// The peripheral being connected or connected, and what its link has proven so far
    private var link: UUID?
    private var setUp = false
    private var encrypted = false

    init(pinned: UUID?) { self.pinned = pinned }

    var reconnect: Reconnect { pinned.map(Reconnect.pinned) ?? .discover }

    /// Whether a peripheral found by a scan (or already connected to the system) may be connected
    func mayConnect(_ id: UUID) -> Bool { pinned == nil || pinned == id }

    /// A connection to `id` starts: nothing is proven on it yet
    mutating func connecting(_ id: UUID) {
        link = id
        setUp = false
        encrypted = false
    }

    /// The translator setup finished on the current link; the identifier to persist when it just became the pin
    mutating func setupFinished() -> UUID? {
        guard link != nil else { return nil }
        setUp = true
        return pinIfProven()
    }

    /// An encrypted characteristic access (the Claude answer subscription) succeeded on the current link; the
    /// identifier to persist when it just became the pin
    mutating func encryptedAccessSucceeded() -> UUID? {
        guard link != nil else { return nil }
        encrypted = true
        return pinIfProven()
    }

    /// Board → relay traffic may be forwarded: an encrypted access succeeded on this link
    var claudeTrusted: Bool { link != nil && encrypted }

    mutating func linkGone() {
        link = nil
        setUp = false
        encrypted = false
    }

    /// Drops the pin and the current link's trust (the caller disconnects and scans again)
    mutating func forget() {
        pinned = nil
        linkGone()
    }

    private mutating func pinIfProven() -> UUID? {
        guard pinned == nil, setUp, encrypted, let link else { return nil }
        pinned = link
        return link
    }
}

/// Where the pinned board's identifier is kept (UserDefaults: an identifier CoreBluetooth gives this app only)
struct BoardPinStore {
    static let key = "ble.pinnedBoard"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> UUID? { defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:)) }

    func save(_ id: UUID?) {
        if let id { defaults.set(id.uuidString, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }
}
