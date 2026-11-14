import Foundation

// ESPLink's bookkeeping, apart from CoreBluetooth so it runs under `swift test` on the Mac. The
// generation-guarded text queue, the label resent on ready, the reconnect backoff. ESPLink owns one of each and uses them on its BLE queue only.

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

/// How much the pinned board proved when it was pinned (stored with the pin)
enum PinSecurity: String, Hashable, Sendable {
    /// Board info version ≥ `BoardPin.secureVersion` and the protected read succeeded: firmware that enforces
    /// pairing by code, so the read went through an authenticated (numeric comparison) link
    case secure
    /// The user explicitly accepted a board that cannot authenticate (old firmware: version < 2 or no control
    /// characteristic). Pins saved before security levels existed load as legacy.
    case legacy
}

/// The question "pin this old-firmware board?" for one link: the peripheral and the link generation it was asked on.
/// The answer must carry both back; an answer for another peripheral or an earlier link is ignored.
struct LegacyConsentRequest: Hashable, Sendable {
    var id: UUID
    var gen: Int
}

/// The pinned board: its CoreBluetooth identifier and how it was pinned
struct PinnedBoard: Hashable, Sendable {
    var id: UUID
    var security: PinSecurity
}

/// Which board this phone talks to (P9 access control). Only that board is reconnected, by identifier
/// (`retrievePeripherals(withIdentifiers:)` + a pending connect); a device found by a scan that is not the pinned
/// board is never connected, whatever it advertises. `forget` drops the pin (a new board) and scanning starts again.
///
/// Pinning (README "BLE pairing"), driven by the board-info version (`…0005`, byte 0) and the protected read of
/// control `…0004`:
/// - No pin, version ≥ 2: pinned `.secure` once the protected read succeeded and the setup finished.
/// - No pin, version < 2 or no control characteristic: never pinned on its own. The link waits (`.askConsent`) and
///   only `acceptLegacy` (the user's "Vẫn ghép") pins it, as `.legacy`; `declineLegacy` ignores that board until
///   `clearDeclined` (the user retries) or `forget`.
/// - Pinned `.secure`: a board that now reports version < 2, has no control characteristic, or whose read succeeds
///   while it reports < 2 is refused (`.refuse`: disconnect, never ready). The pin is never downgraded.
/// - Pinned `.legacy`: set up as before; it becomes `.secure` once it reports version ≥ 2 and the read succeeded.
struct BoardPin {
    /// Board-info version from which the firmware enforces pairing by code
    static let secureVersion = 2

    enum Reconnect: Equatable {
        /// Connect to this identifier only (and wait for it)
        case pinned(UUID)
        /// No board yet: scan for the board service
        case discover
    }

    /// What the link does next
    enum Step: Equatable {
        /// Read the protected characteristic (new firmware asks for the code now)
        case readProtected
        /// Finish the setup (notifications, clock, label, mic, ready), then `setupFinished`
        case finish
        /// Hold the link and ask the user whether to pin this unauthenticated board
        case askConsent
        /// Not this board: disconnect, never ready
        case refuse
    }

    private(set) var pinned: PinnedBoard?
    /// The peripheral being connected or connected
    private var link: UUID?
    /// Bumped on every connect, setup restart and link loss: a consent answer from an earlier link is stale
    private(set) var generation = 0
    /// Board-info version on the current link (0: absent or unreadable)
    private var version = 0
    /// A protected characteristic was read on the current link
    private(set) var proven = false
    /// The user accepted this link's unauthenticated board ("Vẫn ghép")
    private var consented = false
    /// Waiting for the user's answer on the current link
    private(set) var awaitingConsent = false
    /// Boards the user said "Huỷ" to: not connected again until `clearDeclined` or `forget`
    private var declined: Set<UUID> = []

    init(pinned: PinnedBoard?) { self.pinned = pinned }

    var reconnect: Reconnect { pinned.map { .pinned($0.id) } ?? .discover }

    /// Whether a peripheral found by a scan (or already connected to the system) may be connected
    func mayConnect(_ id: UUID) -> Bool {
        if let pinned { return pinned.id == id }
        return !declined.contains(id)
    }

    /// A connection to `id` starts
    mutating func connecting(_ id: UUID) {
        link = id
        setupRestarted()
    }

    /// The translator setup starts over on the same link (services changed): everything proven so far is dropped
    mutating func setupRestarted() {
        generation += 1
        version = 0
        proven = false
        consented = false
        awaitingConsent = false
    }

    /// Board info was read (`version` 0 when absent or unreadable); `hasControl`: the link has control `…0004`
    mutating func boardInfo(version: Int, hasControl: Bool) -> Step {
        guard let link, pinned == nil || pinned?.id == link else { return .refuse }
        self.version = version
        if pinned?.security == .secure, version < Self.secureVersion || !hasControl { return .refuse }
        if hasControl { return .readProtected }
        // Nothing to prove with (very old firmware): a legacy pin was accepted before; a new board needs consent
        return pinned != nil ? .finish : askConsent()
    }

    /// The protected read (`…0004`) succeeded on the current link
    mutating func accessGranted() -> Step {
        guard link != nil else { return .refuse }
        proven = true
        if version >= Self.secureVersion { return .finish }
        switch pinned?.security {
        case .secure?: return .refuse     // a secure board never comes back as old firmware
        case .legacy?: return .finish
        case nil: return askConsent()     // old firmware lets anyone read: no proof
        }
    }

    private mutating func askConsent() -> Step {
        awaitingConsent = true
        return .askConsent
    }

    /// The pending question (`PairingLinkEvent.legacyBoard`); nil when nothing is asked
    var consentRequest: LegacyConsentRequest? {
        guard awaitingConsent, let link else { return nil }
        return LegacyConsentRequest(id: link, gen: generation)
    }

    /// "Vẫn ghép" for the question `id`/`gen`: true when the current link is waiting for exactly that answer (the
    /// caller finishes the setup, which pins it as legacy). A stale answer (another board, an earlier link) is
    /// ignored and logged.
    mutating func acceptLegacy(id: UUID, gen: Int) -> Bool {
        guard answers(id: id, gen: gen, "Vẫn ghép") else { return false }
        awaitingConsent = false
        consented = true
        return true
    }

    /// "Huỷ" for the question `id`/`gen`: the board to disconnect, ignored by `mayConnect` from now on; nil when
    /// nothing was asked or the answer is stale (ignored and logged)
    mutating func declineLegacy(id: UUID, gen: Int) -> UUID? {
        guard answers(id: id, gen: gen, "Huỷ"), let link else { return nil }
        awaitingConsent = false
        declined.insert(link)
        return link
    }

    private func answers(id: UUID, gen: Int, _ what: String) -> Bool {
        guard let asked = consentRequest else { return false }
        guard asked == LegacyConsentRequest(id: id, gen: gen) else {
            Diag.log("ble: stale \(what) ignored (asked \(asked.id) gen \(asked.gen), got \(id) gen \(gen))")
            return false
        }
        return true
    }

    /// The user retries pairing: declined boards may be connected again
    mutating func clearDeclined() { declined.removeAll() }

    /// The translator setup finished on the current link; the pin to persist when it was just made or upgraded.
    /// Nothing is pinned without proof (version ≥ 2 and the read) or the user's consent on this link, and a
    /// `.secure` pin is never replaced by a `.legacy` one.
    mutating func setupFinished() -> PinnedBoard? {
        guard let link else { return nil }
        let level: PinSecurity
        if proven && version >= Self.secureVersion {
            level = .secure
        } else if consented {
            level = .legacy
        } else {
            return nil
        }
        if let pinned {
            // Only the upgrade of this board's legacy pin
            guard pinned.id == link, pinned.security == .legacy, level == .secure else { return nil }
        }
        let made = PinnedBoard(id: link, security: level)
        pinned = made
        return made
    }

    mutating func linkGone() {
        link = nil
        setupRestarted()
    }

    /// Drops the pin (the caller disconnects and scans again)
    mutating func forget() {
        pinned = nil
        declined.removeAll()
        linkGone()
    }
}

/// How a failed protected access maps to pairing (README "BLE pairing"). Errors are given by domain and code so
/// this runs without CoreBluetooth: `CBATTErrorDomain` 5 / 15 / 12 (insufficient authentication / encryption /
/// key size) mean the pairing was refused (Sai, Huỷ, or the board refused); `CBErrorDomain` 15 (encryption timed
/// out) and 6 (connection timeout) a timeout; 14 (peer removed pairing information) a stale bond, which the user
/// fixes by retrying; anything else counts as the link lost.
enum PairingErrorMap {
    static let attDomain = "CBATTErrorDomain"
    static let cbDomain = "CBErrorDomain"

    static func failure(domain: String, code: Int) -> PairingFailure {
        switch (domain, code) {
        case (attDomain, 5), (attDomain, 15), (attDomain, 12): .rejected
        case (cbDomain, 15), (cbDomain, 6): .timeout
        case (cbDomain, 14): .rejected
        default: .lost
        }
    }

    static func failure(_ error: Error) -> PairingFailure {
        let e = error as NSError
        return failure(domain: e.domain, code: e.code)
    }

    /// The board ignores taps for the first second a code is up (firmware PAIR_ARM_US), so a rejection sooner than
    /// this after the protected read went out was not anyone's answer: the board refused the request itself (too
    /// many requests, locked, another code up).
    static let quickRefusal: TimeInterval = 1.0

    /// `failure(_:)`, with a rejection that came `elapsed` seconds after the read was sent: quicker than
    /// `quickRefusal` it is `.refusedByBoard`.
    static func failure(_ error: Error, after elapsed: TimeInterval) -> PairingFailure {
        let f = failure(error)
        return f == .rejected && elapsed < quickRefusal ? .refusedByBoard : f
    }
}

/// The pinned board's protected read, refused (its bond was lost), is read again automatically: after 15, 30 and
/// 60 s, then not until the user taps "Thử lại" or a new link starts (`reset`). Each read is one pairing request
/// and the board rate-limits them (firmware pairing.h), so endless retries would lock the owner out.
struct AuthRetry {
    static let delays: [TimeInterval] = [15, 30, 60]
    private var used = 0

    init() {}

    /// The delay before the next automatic read; nil once they are used up.
    mutating func nextDelay() -> TimeInterval? {
        guard used < Self.delays.count else { return nil }
        defer { used += 1 }
        return Self.delays[used]
    }

    var exhausted: Bool { used >= Self.delays.count }

    mutating func reset() { used = 0 }
}

/// Where the pinned board is kept (UserDefaults: an identifier CoreBluetooth gives this app only). The security
/// level sits under its own key, so a pin saved before levels existed (no level) loads as `.legacy`.
struct BoardPinStore {
    static let key = "ble.pinnedBoard"
    static let securityKey = "ble.pinnedBoardSecurity"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PinnedBoard? {
        guard let id = defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:)) else { return nil }
        let security = defaults.string(forKey: Self.securityKey).flatMap(PinSecurity.init(rawValue:)) ?? .legacy
        return PinnedBoard(id: id, security: security)
    }

    func save(_ pin: PinnedBoard?) {
        if let pin {
            defaults.set(pin.id.uuidString, forKey: Self.key)
            defaults.set(pin.security.rawValue, forKey: Self.securityKey)
        } else {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.securityKey)
        }
    }
}
