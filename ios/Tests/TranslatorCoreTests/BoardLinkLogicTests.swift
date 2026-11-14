import Foundation
import Testing
@testable import TranslatorCore

// ESPLink's bookkeeping without CoreBluetooth (ios/Sources/BLE/BoardLinkLogic.swift): queue, label resend, backoff,
// board pinning.

/// Stands in for a CBCharacteristic: only its identity matters
private final class FakeChar {}

@Suite struct BoardWriteQueueTests {
    @Test func drainsWhileTheLinkCanSendInOrder() {
        var q = BoardWriteQueue<FakeChar>()
        let text = FakeChar()
        q.attach(text)
        let queued = q.replace([Data([1]), Data([2]), Data([3])])
        #expect(queued)
        var budget = 2
        var written: [Data] = []
        q.drain(canSend: { budget > 0 }) { target, chunk in
            #expect(target === text)
            written.append(chunk)
            budget -= 1
        }
        #expect(written == [Data([1]), Data([2])])
        #expect(q.pendingCount == 1)
        budget = 5
        q.drain(canSend: { budget > 0 }) { _, chunk in written.append(chunk); budget -= 1 }
        #expect(written == [Data([1]), Data([2]), Data([3])])
        #expect(q.pendingCount == 0)
    }

    /// A subtitle sent between discovery and the end of setup is kept (as the Swift app always did) and written
    /// only once the link is ready, after the clock and the label
    @Test func chunksQueuedDuringSetupAreWrittenOnceReady() {
        var q = BoardWriteQueue<FakeChar>()
        q.attach(FakeChar(), ready: false)
        let queued = q.replace([Data([5]), Data([6])])
        #expect(queued)
        var written: [Data] = []
        q.drain(canSend: { true }) { _, chunk in written.append(chunk) }
        #expect(written.isEmpty)
        q.markReady()
        q.drain(canSend: { true }) { _, chunk in written.append(chunk) }
        #expect(written == [Data([5]), Data([6])])
    }

    @Test func aNewTextReplacesTheUnsentOne() {
        var q = BoardWriteQueue<FakeChar>()
        q.attach(FakeChar())
        _ = q.replace([Data([1]), Data([2])])
        _ = q.replace([Data([9])])
        var written: [Data] = []
        q.drain(canSend: { true }) { _, chunk in written.append(chunk) }
        #expect(written == [Data([9])])
    }

    @Test func nothingIsQueuedWithoutACharacteristic() {
        var q = BoardWriteQueue<FakeChar>()
        let unattached = q.replace([Data([1])])
        #expect(!unattached)
        #expect(q.pendingCount == 0)
        q.attach(FakeChar())
        q.detach()
        let detached = q.replace([Data([1])])
        #expect(!detached)
    }

    @Test func aResetDropsTheOldQueueAndBumpsTheGeneration() {
        var q = BoardWriteQueue<FakeChar>()
        q.attach(FakeChar())
        _ = q.replace([Data([1]), Data([2])])
        let before = q.generation
        q.attach(FakeChar())  // services reset: a new text characteristic
        #expect(q.generation == before + 1)
        #expect(q.pendingCount == 0)
    }

    /// Review Focus 1: a write on the characteristic of a link that was reset fails late; it must not clear the
    /// queue of the new link
    @Test func aStaleWriteFailureDoesNotClearTheNewQueue() {
        var q = BoardWriteQueue<FakeChar>()
        let old = FakeChar(), fresh = FakeChar()
        q.attach(old)
        _ = q.replace([Data([1])])
        q.attach(fresh)
        _ = q.replace([Data([7]), Data([8])])
        q.writeFailed(on: old)
        #expect(q.pendingCount == 2)
        var written: [Data] = []
        q.drain(canSend: { true }) { target, chunk in
            #expect(target === fresh)
            written.append(chunk)
        }
        #expect(written == [Data([7]), Data([8])])
    }

    @Test func aCurrentWriteFailureClearsTheQueue() {
        var q = BoardWriteQueue<FakeChar>()
        let text = FakeChar()
        q.attach(text)
        _ = q.replace([Data([1]), Data([2])])
        q.writeFailed(on: text)
        #expect(q.pendingCount == 0)
    }
}

/// Review Focus 1: a characteristics discovery that started before a services reset must not set up (and mark
/// ready) the dead characteristics
@Suite struct SetupGuardTests {
    @Test func onlyTheServiceBeingSetUpIsCurrent() {
        var setup = SetupGuard<FakeChar>()
        let old = FakeChar(), fresh = FakeChar()
        #expect(!setup.isCurrent(old))
        setup.begin(old)
        #expect(setup.isCurrent(old))
        setup.reset()  // services reset or drop
        #expect(!setup.isCurrent(old), "a late discovery of the old service is ignored")
        setup.begin(fresh)
        #expect(!setup.isCurrent(old))
        #expect(setup.isCurrent(fresh))
    }
}

@Suite struct ReconnectBackoffTests {
    /// The first rescan after a drop is immediate (as the Swift app always did); from the second consecutive
    /// failure it waits 0.5 s, doubling up to 10 s
    @Test func firstRescanIsImmediateThenDoublesFromHalfASecondUpToTenSeconds() {
        var b = ReconnectBackoff()
        let delays = (0..<9).map { _ in b.nextDelay() }
        #expect(delays == [0, 0.5, 1, 2, 4, 8, 10, 10, 10])
    }

    @Test func resetMakesTheNextRescanImmediateAgain() {
        var b = ReconnectBackoff()
        _ = b.nextDelay()
        _ = b.nextDelay()
        _ = b.nextDelay()
        b.reset()  // the link became ready, or Bluetooth was switched on
        let again = [b.nextDelay(), b.nextDelay(), b.nextDelay()]
        #expect(again == [0, 0.5, 1])
    }

    @Test func customBounds() {
        var b = ReconnectBackoff(base: 1, max: 3)
        let delays = (0..<5).map { _ in b.nextDelay() }
        #expect(delays == [0, 1, 2, 3, 3])
    }
}

@Suite struct AuthRetryTests {
    /// The pinned board's refused protected read is retried automatically a few times, backing off, then waits
    /// for the user ("Thử lại") or a new link: every retry costs one of the board's rate-limited pairing attempts.
    @Test func threeBackedOffRetriesThenStop() {
        var r = AuthRetry()
        #expect(r.nextDelay() == 15)
        #expect(r.nextDelay() == 30)
        #expect(r.nextDelay() == 60)
        #expect(r.nextDelay() == nil)
        #expect(r.nextDelay() == nil)
        #expect(r.exhausted)
        r.reset()   // "Thử lại", a new link, or the read went through
        #expect(!r.exhausted)
        #expect(r.nextDelay() == 15)
    }
}

@Suite struct BoardLabelTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func aLabelIsSentOnlyToABoardThatHasBoardInfo() {
        var label = BoardLabel()
        let before = label.send("English")
        #expect(before == nil, "older firmware shows unknown kinds as subtitles")
        label.boardInfo(parsed: true)
        let after = label.send("English")
        #expect(after == "English")
    }

    /// The next link may be older firmware: until its board info is read no label goes out, but the label is
    /// remembered for the resend on ready
    @Test func aLostLinkForgetsLabelSupportButKeepsTheLabel() {
        var label = BoardLabel()
        label.boardInfo(parsed: true)
        _ = label.send("English")
        label.linkGone()
        let meanwhile = label.send("日本語")
        #expect(meanwhile == nil)
        #expect(label.last == "日本語")
        let date = Date(timeIntervalSince1970: 0), utc = TimeZone(secondsFromGMT: 0)!
        #expect(label.readyFrames(maxWrite: 185, at: date, in: utc) == [BoardProtocol.timeFrame(at: date, in: utc)])
    }

    @Test func aLabelIsCutTo32BytesAtACharacterBoundary() {
        var label = BoardLabel()
        label.boardInfo(parsed: true)
        let long = String(repeating: "ế", count: 20)  // 3 bytes each
        let sent = label.send(long)
        #expect(sent == String(repeating: "ế", count: 10))
        #expect(sent!.utf8.count <= BoardProtocol.maxLabelBytes)
    }

    /// Review Focus 1: on ready the clock goes first, then the label the board forgot (kind 3)
    @Test func readyFramesAreTheClockThenTheRememberedLabel() {
        var label = BoardLabel()
        _ = label.send("日本語")  // before the board is known: remembered
        label.boardInfo(parsed: true)
        let frames = label.readyFrames(maxWrite: 185, at: date, in: utc)
        #expect(frames.count == 2)
        #expect(frames[0] == BoardProtocol.timeFrame(at: date, in: utc))
        #expect(frames[1] == BoardProtocol.frameText("日本語", kind: .label, maxWrite: 185)[0])
        #expect(frames[1][1] == 3)
    }

    @Test func readyFramesWithoutBoardInfoAreOnlyTheClock() {
        var label = BoardLabel()
        _ = label.send("English")
        label.boardInfo(parsed: false)
        #expect(label.readyFrames(maxWrite: 185, at: date, in: utc) == [BoardProtocol.timeFrame(at: date, in: utc)])
    }

    @Test func readyFramesWithoutALabelAreOnlyTheClock() {
        var label = BoardLabel()
        label.boardInfo(parsed: true)
        #expect(label.readyFrames(maxWrite: 185, at: date, in: utc) == [BoardProtocol.timeFrame(at: date, in: utc)])
    }

    @Test func boardInfoFallsBackToLatinVIWhenAbsentOrShort() {
        #expect(BoardLabel.info(from: nil) == BoardInfo(protocolVersion: 0, fontSets: .latinVI))
        #expect(BoardLabel.info(from: Data([1, 2])) == BoardInfo(protocolVersion: 0, fontSets: .latinVI))
        #expect(BoardLabel.info(from: Data([1, 0x1F, 0, 0, 0]))
                == BoardInfo(protocolVersion: 1, fontSets: FontSets(rawValue: 0x1F)))
    }
}

// MARK: Board pinning (P9 access control)

@Suite struct BoardPinTests {
    private let board = UUID()
    private let stranger = UUID()
    private var secure: PinnedBoard { PinnedBoard(id: board, security: .secure) }
    private var legacy: PinnedBoard { PinnedBoard(id: board, security: .legacy) }

    @Test func withoutAPinTheFirstBoardIsFoundByScanning() {
        let pin = BoardPin(pinned: nil)
        #expect(pin.reconnect == .discover)
        #expect(pin.mayConnect(board))
        #expect(pin.mayConnect(stranger))
    }

    /// A pinned board is reconnected by identifier only: a device found by a scan that is not the pinned board is
    /// never connected, even when it advertises the board service
    @Test(arguments: [PinSecurity.secure, .legacy])
    func aPinnedBoardIsReconnectedByIdentifierOnly(_ level: PinSecurity) {
        let pin = BoardPin(pinned: PinnedBoard(id: board, security: level))
        #expect(pin.reconnect == .pinned(board))
        #expect(pin.mayConnect(board))
        #expect(!pin.mayConnect(stranger))
    }

    // MARK: Decision tables

    /// One link: board info (version, control characteristic), then the protected read if asked for
    struct Row: CustomTestStringConvertible, Sendable {
        let pinned: PinSecurity?
        let version: Int
        let hasControl: Bool
        /// Decision after board info
        let afterInfo: BoardPin.Step
        /// Decision after a successful protected read (only when `afterInfo == .readProtected`)
        let afterRead: BoardPin.Step?
        /// The pin after `setupFinished` (when the setup finishes without consent)
        let pinAfter: PinSecurity?
        var testDescription: String { "pin \(pinned.map(\.rawValue) ?? "none") v\(version) control \(hasControl)" }
    }

    static let rows: [Row] = [
        // First connection
        Row(pinned: nil, version: 2, hasControl: true, afterInfo: .readProtected, afterRead: .finish, pinAfter: .secure),
        Row(pinned: nil, version: 3, hasControl: true, afterInfo: .readProtected, afterRead: .finish, pinAfter: .secure),
        Row(pinned: nil, version: 1, hasControl: true, afterInfo: .readProtected, afterRead: .askConsent, pinAfter: nil),
        Row(pinned: nil, version: 0, hasControl: true, afterInfo: .readProtected, afterRead: .askConsent, pinAfter: nil),
        Row(pinned: nil, version: 2, hasControl: false, afterInfo: .askConsent, afterRead: nil, pinAfter: nil),
        Row(pinned: nil, version: 0, hasControl: false, afterInfo: .askConsent, afterRead: nil, pinAfter: nil),
        // Reconnecting a secure pin
        Row(pinned: .secure, version: 2, hasControl: true, afterInfo: .readProtected, afterRead: .finish, pinAfter: .secure),
        Row(pinned: .secure, version: 1, hasControl: true, afterInfo: .refuse, afterRead: nil, pinAfter: .secure),
        Row(pinned: .secure, version: 0, hasControl: true, afterInfo: .refuse, afterRead: nil, pinAfter: .secure),
        Row(pinned: .secure, version: 2, hasControl: false, afterInfo: .refuse, afterRead: nil, pinAfter: .secure),
        Row(pinned: .secure, version: 0, hasControl: false, afterInfo: .refuse, afterRead: nil, pinAfter: .secure),
        // Reconnecting a legacy pin
        Row(pinned: .legacy, version: 2, hasControl: true, afterInfo: .readProtected, afterRead: .finish, pinAfter: .secure),
        Row(pinned: .legacy, version: 1, hasControl: true, afterInfo: .readProtected, afterRead: .finish, pinAfter: .legacy),
        Row(pinned: .legacy, version: 0, hasControl: false, afterInfo: .finish, afterRead: nil, pinAfter: .legacy),
    ]

    @Test(arguments: rows)
    func decisions(_ row: Row) {
        var pin = BoardPin(pinned: row.pinned.map { PinnedBoard(id: board, security: $0) })
        pin.connecting(board)
        #expect(pin.boardInfo(version: row.version, hasControl: row.hasControl) == row.afterInfo)
        if row.afterInfo == .readProtected {
            #expect(pin.accessGranted() == row.afterRead)
        } else {
            #expect(row.afterRead == nil)
        }
        let finishes = (row.afterRead ?? row.afterInfo) == .finish
        let made = finishes ? pin.setupFinished() : nil
        #expect(pin.pinned?.security == row.pinAfter)
        #expect(pin.awaitingConsent == ((row.afterRead ?? row.afterInfo) == .askConsent))
        // Something to persist only when a pin was made or upgraded
        #expect((made != nil) == (finishes && row.pinned != row.pinAfter))
    }

    /// The table's own "the read succeeds while board info says < 2" case for a secure pin: even if the link read
    /// anyway, the success is refused and the pin stays secure
    @Test func aSecurePinRefusesAReadThatSucceedsOnOldFirmware() {
        var pin = BoardPin(pinned: secure)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: true)
        #expect(pin.accessGranted() == .refuse)
        #expect(pin.setupFinished() == nil)
        #expect(pin.pinned == secure)
    }

    /// No pin is ever made without proof or consent, whatever order the link calls in
    @Test func noPinWithoutProofOrConsent() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        #expect(pin.setupFinished() == nil)                       // no board info, no read
        _ = pin.boardInfo(version: 2, hasControl: true)
        #expect(pin.setupFinished() == nil)                       // the read has not succeeded
        _ = pin.accessGranted()
        pin.linkGone()                                            // the proof belongs to the link that gave it
        pin.connecting(board)
        #expect(!pin.proven)
        #expect(pin.setupFinished() == nil)
        // A services reset on the same link drops the proof too
        _ = pin.boardInfo(version: 2, hasControl: true)
        _ = pin.accessGranted()
        pin.setupRestarted()
        #expect(pin.setupFinished() == nil)
        // Proof without a link is refused
        var lone = BoardPin(pinned: nil)
        #expect(lone.accessGranted() == .refuse)
        #expect(lone.boardInfo(version: 2, hasControl: true) == .refuse)
        #expect(!lone.proven)
    }

    /// A pinned board's identifier is the only one set up, even if the link reached another one
    @Test func aStrangerOnAPinnedLinkIsRefused() {
        var pin = BoardPin(pinned: legacy)
        pin.connecting(stranger)
        #expect(pin.boardInfo(version: 2, hasControl: true) == .refuse)
    }

    // MARK: Consent

    @Test(arguments: [true, false])
    func onlyVanGhepPinsAnOldBoardAsLegacy(_ hasControl: Bool) {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        let step = pin.boardInfo(version: 1, hasControl: hasControl)
        if hasControl { #expect(pin.accessGranted() == .askConsent) } else { #expect(step == .askConsent) }
        #expect(pin.setupFinished() == nil)                       // waiting: nothing pinned
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == true)
        #expect(!pin.awaitingConsent)
        #expect(pin.setupFinished() == legacy)
        #expect(pin.reconnect == .pinned(board))
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == false)                              // asked once
    }

    @Test func consentIsOnlyTakenWhenAsked() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.boardInfo(version: 2, hasControl: true)
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == false)                              // a secure board is never pinned as legacy
        #expect(pin.declineLegacy(id: board, gen: pin.generation) == nil)
        _ = pin.accessGranted()
        #expect(pin.setupFinished() == secure)
    }

    @Test func consentBelongsToItsLink() throws {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        let asked = try #require(pin.consentRequest)
        #expect(asked == LegacyConsentRequest(id: board, gen: pin.generation))
        pin.linkGone()
        #expect(pin.consentRequest == nil)
        #expect(pin.acceptLegacy(id: asked.id, gen: asked.gen) == false)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == true)
        pin.linkGone()
        pin.connecting(board)
        #expect(pin.setupFinished() == nil)                       // the consent did not carry over
    }

    /// The warning was answered late: the link dropped and reconnected (to another board, or to the same one) and
    /// that link asks again. An answer carrying the old link's identifier or generation is ignored.
    @Test func aStaleConsentAfterAReconnectIsIgnored() throws {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        let first = try #require(pin.consentRequest)
        pin.linkGone()
        pin.connecting(stranger)
        _ = pin.boardInfo(version: 1, hasControl: false)
        let second = try #require(pin.consentRequest)
        #expect(second.id == stranger && second.gen != first.gen)
        #expect(pin.acceptLegacy(id: first.id, gen: first.gen) == false, "the first board's answer")
        #expect(pin.declineLegacy(id: first.id, gen: first.gen) == nil)
        #expect(pin.acceptLegacy(id: stranger, gen: first.gen) == false, "the right board, an old generation")
        #expect(pin.awaitingConsent, "still waiting for this link's own answer")
        #expect(pin.setupFinished() == nil)
        #expect(pin.mayConnect(board), "a stale Huỷ declines nothing")

        // The same board reconnected: an answer from before the reconnect is ignored too
        pin.linkGone()
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        let third = try #require(pin.consentRequest)
        #expect(pin.acceptLegacy(id: board, gen: first.gen) == false)
        #expect(pin.acceptLegacy(id: third.id, gen: third.gen) == true)
        #expect(pin.setupFinished() == legacy)
    }

    @Test func aServicesResetOnTheSameLinkVoidsTheQuestion() throws {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        let asked = try #require(pin.consentRequest)
        pin.setupRestarted()
        _ = pin.boardInfo(version: 1, hasControl: false)
        #expect(pin.acceptLegacy(id: asked.id, gen: asked.gen) == false)
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == true)
    }

    @Test func huyIgnoresThatBoardUntilARetry() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: true)
        _ = pin.accessGranted()
        #expect(pin.declineLegacy(id: board, gen: pin.generation) == board)
        #expect(pin.setupFinished() == nil)
        #expect(pin.pinned == nil)
        pin.linkGone()
        #expect(!pin.mayConnect(board))
        #expect(pin.mayConnect(stranger))
        pin.clearDeclined()
        #expect(pin.mayConnect(board))
        // forget clears it too
        pin.connecting(board)
        _ = pin.boardInfo(version: 1, hasControl: false)
        _ = pin.declineLegacy(id: board, gen: pin.generation)
        pin.forget()
        #expect(pin.mayConnect(board))
    }

    // MARK: Upgrade, never downgrade

    @Test func aLegacyPinBecomesSecureOnceTheBoardProvesIt() {
        var pin = BoardPin(pinned: legacy)
        pin.connecting(board)
        #expect(pin.boardInfo(version: 2, hasControl: true) == .readProtected)
        #expect(pin.setupFinished() == nil)                       // not before the read
        #expect(pin.accessGranted() == .finish)
        #expect(pin.setupFinished() == secure)
        // From now on old firmware is refused
        pin.linkGone()
        pin.connecting(board)
        #expect(pin.boardInfo(version: 1, hasControl: true) == .refuse)
        #expect(pin.pinned == secure)
    }

    @Test func aSecurePinIsNeverDowngraded() {
        var pin = BoardPin(pinned: secure)
        pin.connecting(board)
        _ = pin.boardInfo(version: 0, hasControl: false)
        #expect(pin.acceptLegacy(id: board, gen: pin.generation) == false)                              // no consent asked, none taken
        #expect(pin.setupFinished() == nil)
        #expect(pin.pinned == secure)
    }

    @Test func pairingErrorsMapToFailures() {
        #expect(PairingErrorMap.failure(domain: "CBATTErrorDomain", code: 5) == .rejected)
        #expect(PairingErrorMap.failure(domain: "CBATTErrorDomain", code: 15) == .rejected)
        #expect(PairingErrorMap.failure(domain: "CBErrorDomain", code: 15) == .timeout)
        #expect(PairingErrorMap.failure(domain: "CBErrorDomain", code: 14) == .rejected)
        #expect(PairingErrorMap.failure(domain: "CBErrorDomain", code: 7) == .lost)
        #expect(PairingErrorMap.failure(NSError(domain: "CBATTErrorDomain", code: 5)) == .rejected)
    }

    /// The board refuses a request it rate-limits (or while locked or busy) at once, before anyone could answer:
    /// a tap on the board counts only after the code was up for 1 s. A rejection that quick is the board refusing.
    @Test func aRejectionFasterThanAnyTapIsTheBoardRefusing() {
        let refused = NSError(domain: "CBATTErrorDomain", code: 15)
        #expect(PairingErrorMap.failure(refused, after: 0.3) == .refusedByBoard)
        #expect(PairingErrorMap.failure(refused, after: PairingErrorMap.quickRefusal - 0.01) == .refusedByBoard)
        #expect(PairingErrorMap.failure(refused, after: 4) == .rejected, "Sai on the board, or Huỷ on the iPhone")
        // Only rejections: a quick timeout or loss stays what it is
        #expect(PairingErrorMap.failure(NSError(domain: "CBErrorDomain", code: 7), after: 0.1) == .lost)
        #expect(PairingErrorMap.failure(NSError(domain: "CBErrorDomain", code: 15), after: 0.1) == .timeout)
    }

    @Test func forgettingClearsThePin() {
        var pin = BoardPin(pinned: secure)
        pin.connecting(board)
        pin.forget()
        #expect(pin.pinned == nil)
        #expect(pin.reconnect == .discover)
        #expect(pin.mayConnect(stranger))
        // The next board is pinned again on its own proof
        pin.connecting(stranger)
        _ = pin.boardInfo(version: 2, hasControl: true)
        _ = pin.accessGranted()
        #expect(pin.setupFinished() == PinnedBoard(id: stranger, security: .secure))
    }

    // MARK: Persistence

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "board-pin-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func thePinAndItsLevelAreKeptInUserDefaults() throws {
        try withDefaults { defaults in
            let store = BoardPinStore(defaults: defaults)
            #expect(store.load() == nil)
            store.save(secure)
            #expect(BoardPinStore(defaults: defaults).load() == secure)
            store.save(legacy)
            #expect(BoardPinStore(defaults: defaults).load() == legacy)
            store.save(nil)
            #expect(BoardPinStore(defaults: defaults).load() == nil)
            #expect(defaults.object(forKey: BoardPinStore.securityKey) == nil)
            // Anything that is not a UUID is no pin
            defaults.set("not a uuid", forKey: BoardPinStore.key)
            #expect(store.load() == nil)
        }
    }

    /// A pin saved before levels existed (identifier only) loads as legacy: it is not trusted as secure, and
    /// upgrades once the board proves itself
    @Test func anOldPinWithoutALevelLoadsAsLegacy() throws {
        try withDefaults { defaults in
            defaults.set(board.uuidString, forKey: BoardPinStore.key)
            #expect(BoardPinStore(defaults: defaults).load() == legacy)
            defaults.set("bogus", forKey: BoardPinStore.securityKey)
            #expect(BoardPinStore(defaults: defaults).load() == legacy)
        }
    }
}
