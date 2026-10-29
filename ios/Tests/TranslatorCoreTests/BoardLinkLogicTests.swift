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

@Suite struct ReconnectBackoffTests {
    @Test func doublesFromHalfASecondUpToTenSeconds() {
        var b = ReconnectBackoff()
        let delays = (0..<8).map { _ in b.nextDelay() }
        #expect(delays == [0.5, 1, 2, 4, 8, 10, 10, 10])
    }

    @Test func resetStartsAgainAtHalfASecond() {
        var b = ReconnectBackoff()
        _ = b.nextDelay()
        _ = b.nextDelay()
        _ = b.nextDelay()
        b.reset()  // the link became ready, or Bluetooth was switched on
        let again = [b.nextDelay(), b.nextDelay()]
        #expect(again == [0.5, 1])
    }

    @Test func customBounds() {
        var b = ReconnectBackoff(base: 1, max: 3)
        let delays = (0..<4).map { _ in b.nextDelay() }
        #expect(delays == [1, 2, 3, 3])
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
