import Foundation
import Testing
@testable import TranslatorCore

// The Live screen's pure helpers: the board level meter, the audio ranges on the session clock, the edit field.

struct BoardLevelMeterTests {
    private func tone(amplitude: Double, count: Int = 320) -> [Int16] {
        (0..<count).map { Int16((sin(Double($0) * 0.3) * amplitude * 32767).rounded()) }
    }

    @Test func silenceAndEmptyAreZero() {
        #expect(BoardLevelMeter.level([]) == 0)
        #expect(BoardLevelMeter.level([Int16](repeating: 0, count: 320)) == 0)
        #expect(BoardLevelMeter.dbfs([]) == -.infinity)
    }

    @Test func mapsLikeTheBoardsRing() {
        // A full-scale square wave is 0 dBFS → the top of the ring
        #expect(BoardLevelMeter.level([Int16](repeating: 32767, count: 160) + [Int16](repeating: -32767, count: 160)) == 1)
        // -40 dBFS (RMS 0.01) is the middle of -55…-25
        let mid = BoardLevelMeter.level([Int16](repeating: 328, count: 320))
        #expect(abs(mid - 0.5) < 0.01)
        // Below -55 dBFS: nothing
        #expect(BoardLevelMeter.level(tone(amplitude: 0.001)) == 0)
        // Louder is never lower
        #expect(BoardLevelMeter.level(tone(amplitude: 0.05)) <= BoardLevelMeter.level(tone(amplitude: 0.2)))
    }
}

struct AudioRangesTests {
    @Test func theirResultEndsAtTheLastPacketAndUsesTheRecognizersLength() throws {
        var r = AudioRanges()
        r.boardPacket(at: 10.02, seconds: 0.02)
        r.boardPacket(at: 10.5, seconds: 0.02)
        r.boardPacket(at: 11.0, seconds: 0.02)
        // The result arrives later (recognizer latency); its range still ends at the last packet
        let range = try #require(r.theirs(at: 11.6, audio: 0.8))
        #expect(abs(range.upperBound - 11.0) < 1e-9)
        #expect(abs(range.lowerBound - 10.2) < 1e-9)
    }

    @Test func withoutALengthTheRangeIsTheRunOfPackets() throws {
        var r = AudioRanges()
        r.boardPacket(at: 5, seconds: 0.02)
        r.boardPacket(at: 9, seconds: 0.02)   // a gap > runGap: a new run
        r.boardPacket(at: 9.3, seconds: 0.02)
        let range = try #require(r.theirs(at: 10, audio: nil))
        #expect(abs(range.lowerBound - 8.98) < 1e-9)
        #expect(range.upperBound == 9.3)
    }

    @Test func withoutBoardPacketsTheResultsArrivalEndsIt() throws {
        let r = AudioRanges()
        #expect(r.theirs(at: 3, audio: nil) == nil)
        let range = try #require(r.theirs(at: 3, audio: 1.5))
        #expect(range == 1.5...3)
    }

    @Test func stalePacketsAreNotTheEnd() throws {
        var r = AudioRanges()
        r.boardPacket(at: 1, seconds: 0.02)
        let range = try #require(r.theirs(at: 100, audio: 2))
        #expect(range == 98...100)
    }

    @Test func myTurnIsTheUnionOfItsResults() {
        var r = AudioRanges()
        #expect(r.mine(turn: 1, at: 10, audio: 1) == 9...10)
        #expect(r.mine(turn: 1, at: 11, audio: 1.5) == 9...11)
        #expect(r.mine(turn: 2, at: 20, audio: 0.5) == 19.5...20)
        #expect(r.mine(turn: 1, at: 12, audio: 0) == 9...12)
        r.reset()
        #expect(r.mine(turn: 1, at: 30, audio: 1) == 29...30)
    }

    @Test func neverNegative() {
        var r = AudioRanges()
        #expect(r.mine(turn: 1, at: 0.5, audio: 2) == 0...0.5)
        #expect(r.theirs(at: 0.5, audio: 2) == 0...0.5)
    }

    @Test func theSystemClockIsMonotonic() {
        let a = SessionClock.system.now(), b = SessionClock.system.now()
        #expect(b >= a)
    }
}

struct LineEditTextTests {
    @Test func editsTheTranslationOrThePendingSource() {
        let at = Date()
        #expect(LineEditText.initial(UILine(id: "1", mine: true, source: "xin chào", target: "hello", at: at)) == "hello")
        #expect(LineEditText.initial(UILine(id: "2", mine: false, source: "hi", target: "", at: at)) == "hi")
    }
}
