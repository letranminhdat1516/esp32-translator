import XCTest
@testable import TranslatorCore

/// A manual clock and scheduler for `BoardSilencePadder`: work runs only when the test advances time
@MainActor
final class ManualScheduler {
    private struct Item {
        let id: Int
        let at: TimeInterval
        let work: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var nextID = 0

    var pending: Int { items.count }

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        items.append(Item(id: id, at: now + max(0, delay), work: work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    /// Runs every item due up to `t`, in time order, moving the clock to each one
    func advance(to t: TimeInterval) {
        while let next = items.filter({ $0.at <= t + 1e-9 }).min(by: { $0.at < $1.at || ($0.at == $1.at && $0.id < $1.id) }) {
            items.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.work()
        }
        now = max(now, t)
    }
}

@MainActor
final class BoardSilencePadderTests: XCTestCase {
    private let config = BoardSilencePadder.Config()
    private var clock: ManualScheduler!
    private var padded: [(at: TimeInterval, frames: Int)] = []
    private var alive = true

    override func setUp() async throws {
        clock = ManualScheduler()
        padded = []
        alive = true
    }

    private func padder() -> BoardSilencePadder {
        let clock = self.clock!
        return BoardSilencePadder(now: { clock.now }, schedule: { clock.schedule($0, $1) },
                                  pad: { [unowned self] frames in
                                      guard alive else { return false }
                                      padded.append((clock.now, frames))
                                      return true
                                  })
    }

    private var paddedSeconds: TimeInterval { Double(padded.map(\.frames).reduce(0, +)) * config.frame }

    func testTheDefaultsAreTheMeasuredOnes() {
        XCTAssertEqual(config.frame, 0.02, "20 ms frames, as the board's packets and the harness's PAD=silence")
        XCTAssertEqual(config.limit, 3)
    }

    func testNeverPadsBeforeTheFirstPacket() {
        let p = padder()
        clock.advance(to: 10)
        XCTAssertTrue(padded.isEmpty)
        XCTAssertEqual(clock.pending, 0)
        XCTAssertFalse(p.isPadding)
    }

    /// The first pad comes once the packet's audio has played out plus the BLE grace; it catches up on the whole
    /// gap at once, then one frame per tick, so the recognizer's audio keeps pace with the wall clock
    func testPadsInRealTimeAfterAGap() {
        let p = padder()
        p.audioArrived(seconds: 0.04)
        clock.advance(to: 0.04 + config.grace - 0.001)
        XCTAssertTrue(padded.isEmpty, "no padding while the next BLE packet may still be on its way")
        clock.advance(to: 0.04 + config.grace)
        XCTAssertEqual(padded.count, 1)
        XCTAssertEqual(paddedSeconds, config.grace, accuracy: 0.0001, "the whole gap so far is filled at once")
        XCTAssertTrue(p.isPadding)
        clock.advance(to: 1.04)
        XCTAssertEqual(paddedSeconds, 1.0, accuracy: 0.021)
        XCTAssertTrue(padded.dropFirst().allSatisfy { $0.frames == 1 }, "then one 20 ms frame per tick")
    }

    func testStopsAfterTheLimit() {
        let p = padder()
        p.audioArrived(seconds: 0.02)
        clock.advance(to: 30)
        XCTAssertEqual(paddedSeconds, config.limit, accuracy: 0.0001)
        XCTAssertEqual(clock.pending, 0, "no timer left running after the limit")
        XCTAssertFalse(p.isPadding)
    }

    func testANewPacketCancelsThePendingPadAndRestartsTheBudget() {
        let p = padder()
        p.audioArrived(seconds: 0.02)
        clock.advance(to: 0.1)
        p.audioArrived(seconds: 0.02)
        // The first packet's pad (due at 0.12) was cancelled: the next one is due 0.02 + grace after 0.1
        clock.advance(to: 0.12 + config.grace - 0.001)
        XCTAssertTrue(padded.isEmpty)
        clock.advance(to: 2.5)
        XCTAssertGreaterThan(paddedSeconds, 0)
        // A packet in the middle of padding: nothing more is fed until after the new gap
        let before = padded.count
        p.audioArrived(seconds: 0.02)
        XCTAssertEqual(clock.pending, 1, "only the new packet's timer is left")
        clock.advance(to: 2.5 + 0.02 + config.grace - 0.001)
        XCTAssertEqual(padded.count, before, "a real packet cancels the pending pad tick")
        // A fresh 3 s budget after the new packet
        padded = []
        clock.advance(to: 20)
        XCTAssertEqual(paddedSeconds, config.limit, accuracy: 0.0001)
    }

    func testABurstOfPacketsDoesNotStartPaddingEarly() {
        let p = padder()
        // Two 20 ms packets per BLE connection event every 40 ms
        for event in 0..<10 {
            clock.advance(to: Double(event) * 0.04)
            p.audioArrived(seconds: 0.02)
            p.audioArrived(seconds: 0.02)
        }
        XCTAssertTrue(padded.isEmpty)
        clock.advance(to: 0.36 + 0.04 + config.grace + 0.001)
        XCTAssertFalse(padded.isEmpty)
    }

    func testStopsWhenTheRecognizerIsGone() {
        let p = padder()
        p.audioArrived(seconds: 0.02)
        clock.advance(to: 0.5)
        let count = padded.count
        alive = false
        clock.advance(to: 5)
        XCTAssertEqual(padded.count, count)
        XCTAssertEqual(clock.pending, 0)
        XCTAssertFalse(p.isPadding)
    }

    func testStopCancelsAndForgetsThePacket() {
        let p = padder()
        p.audioArrived(seconds: 0.02)
        clock.advance(to: 0.5)
        let count = padded.count
        p.stop()
        clock.advance(to: 5)
        XCTAssertEqual(padded.count, count)
        XCTAssertEqual(clock.pending, 0)
    }
}
