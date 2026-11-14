import Foundation
import Testing
@testable import TranslatorCore

// ESPLink's bookkeeping without CoreBluetooth (ios/Sources/BLE/BoardLinkLogic.swift); behaviour of
// app/lib/board/ble_board_link.dart (queue, label resend, backoff) and its test app/test/board/ble_board_link_test.dart.

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

    @Test func withoutAPinTheFirstBoardIsFoundByScanning() {
        let pin = BoardPin(pinned: nil)
        #expect(pin.reconnect == .discover)
        #expect(pin.mayConnect(board))
        #expect(pin.mayConnect(stranger))
    }

    /// A pinned board is reconnected by identifier only: a device found by a scan that is not the pinned board is
    /// never connected, even when it advertises the board service
    @Test func aPinnedBoardIsReconnectedByIdentifierOnly() {
        let pin = BoardPin(pinned: board)
        #expect(pin.reconnect == .pinned(board))
        #expect(pin.mayConnect(board))
        #expect(!pin.mayConnect(stranger))
    }

    @Test func theBoardIsPinnedOnlyOnceSetupAndAnEncryptedAccessSucceededOnTheSameLink() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        #expect(pin.setupFinished() == nil)          // set up, but nothing proves the link is the bonded board yet
        #expect(pin.pinned == nil)
        #expect(pin.encryptedAccessSucceeded() == board)
        #expect(pin.pinned == board)
        #expect(pin.reconnect == .pinned(board))
        // Already pinned: nothing more to persist
        #expect(pin.setupFinished() == nil)
        #expect(pin.encryptedAccessSucceeded() == nil)
    }

    @Test func theOrderOfSetupAndEncryptedAccessDoesNotMatter() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        #expect(pin.encryptedAccessSucceeded() == nil)
        #expect(pin.setupFinished() == board)
        #expect(pin.pinned == board)
    }

    /// Setup on one link and an encrypted access on another (a drop in between) do not pin
    @Test func aDropResetsWhatTheLinkHasProven() {
        var pin = BoardPin(pinned: nil)
        pin.connecting(board)
        _ = pin.setupFinished()
        pin.linkGone()
        #expect(pin.encryptedAccessSucceeded() == nil)   // no link
        pin.connecting(stranger)
        #expect(pin.encryptedAccessSucceeded() == nil)   // this link was not set up yet
        #expect(pin.pinned == nil)
    }

    /// First connection: the relay forwards nothing from the board until an encrypted access succeeded on this link
    @Test func claudeTrafficWaitsForTheEncryptedAccess() {
        var pin = BoardPin(pinned: nil)
        #expect(!pin.claudeTrusted)
        pin.connecting(board)
        _ = pin.setupFinished()
        #expect(!pin.claudeTrusted)
        _ = pin.encryptedAccessSucceeded()
        #expect(pin.claudeTrusted)
        pin.linkGone()
        #expect(!pin.claudeTrusted)
        // The next link of the pinned board proves itself again (the board's Claude service is encrypted)
        pin.connecting(board)
        #expect(!pin.claudeTrusted)
        _ = pin.encryptedAccessSucceeded()
        #expect(pin.claudeTrusted)
    }

    @Test func forgettingClearsThePinAndTheLinkTrust() {
        var pin = BoardPin(pinned: board)
        pin.connecting(board)
        _ = pin.encryptedAccessSucceeded()
        pin.forget()
        #expect(pin.pinned == nil)
        #expect(pin.reconnect == .discover)
        #expect(!pin.claudeTrusted)
        #expect(pin.mayConnect(stranger))
    }

    @Test func thePinIsKeptInUserDefaults() throws {
        let suite = "board-pin-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardPinStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(board)
        #expect(BoardPinStore(defaults: defaults).load() == board)
        store.save(nil)
        #expect(BoardPinStore(defaults: defaults).load() == nil)
        // Anything that is not a UUID is no pin
        defaults.set("not a uuid", forKey: BoardPinStore.key)
        #expect(store.load() == nil)
    }
}
