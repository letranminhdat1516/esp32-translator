import Foundation
import Observation
import Testing
@testable import TranslatorCore

// ConversationController's Live-screen wiring (track B): level and partials in their leaf models (never in `UIState`),
// the board subtitle, audio ranges, the board-lost facts, line actions and phone-only.

/// Every stored value of the screen model, as text (closures print as "(Function)"): equal snapshots mean the
/// screen model was not touched.
@MainActor
private func snapshot(_ ui: UIState) -> [String: String] {
    var out: [String: String] = [:]
    for child in Mirror(reflecting: ui).children {
        guard let label = child.label, !label.contains("$") else { continue }
        out[label] = String(describing: child.value)
    }
    return out
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite(.serialized) @MainActor
struct LiveControllerTests {
    /// A loud ADPCM packet (the step index climbs to full scale).
    private func loud(_ rig: Rig, seq: UInt16) {
        rig.board.emitAudio(Data([UInt8(seq & 0xFF), UInt8(seq >> 8), 0, 0, 60] + [UInt8](repeating: 0x77, count: 40)))
    }

    @Test func levelUpdatesNeverTouchTheScreenModel() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        #expect(await eventually { rig.ui.listening })
        loud(rig, seq: 0)
        #expect(await eventually { rig.controller.level.level > 0.5 })
        await settle()

        let before = snapshot(rig.ui)
        #expect(before.keys.contains("_lines"), "the snapshot sees the stored properties")
        let changed = Flag()
        withObservationTracking {
            _ = rig.ui.lines
            _ = rig.ui.boardSubtitle
            _ = rig.ui.listening
            _ = rig.ui.board
        } onChange: { changed.set() }

        for seq in UInt16(1)...40 {
            if seq % 2 == 0 { loud(rig, seq: seq) } else { rig.boardAudio(seq: seq) }
        }
        #expect(await eventually { await rig.fake.fed.count == 41 })
        await settle()
        #expect(!changed.isSet, "a level change re-renders nothing that reads the screen model")
        #expect(snapshot(rig.ui) == before)
    }

    @Test func theRingFallsToZeroWhenTheBoardStopsStreaming() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        loud(rig, seq: 0)
        #expect(await eventually { rig.controller.level.level > 0.5 })
        #expect(await eventually { rig.controller.level.level == 0 })
    }

    @Test func partialsGoToThePartialModel() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.mine("xin chà", final: false)
        #expect(await eventually { rig.controller.partials.mine == "xin chà" })
    }

    @Test func theDialShowsWhatWasSentToTheBoard() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.mine("xin chào", final: true)
        #expect(await eventually { rig.ui.boardSubtitle == "[en]xin chào" })
        #expect(await eventually { rig.sent(.subtitle).last == "[en]xin chào" })
        rig.ui.clear()
        #expect(rig.ui.boardSubtitle == "")
    }

    @Test func linesCarryAudioRangesOnTheSessionClock() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        let t0 = SessionClock.system.now()
        rig.boardAudio(seq: 0)
        rig.boardAudio(seq: 1)
        #expect(await eventually { await rig.fake.fed.count == 2 })
        rig.fake.emitTheirs(TheirsMsg(text: "Hello there", confidence: 0.9, generation: 0, audio: 0.5))
        #expect(await eventually { rig.ui.lines.contains { !$0.mine } })
        let theirs = try #require(rig.ui.lines.first { !$0.mine }?.audioRange)
        #expect(theirs.upperBound >= t0 && theirs.upperBound <= SessionClock.system.now())
        #expect(abs(theirs.upperBound - theirs.lowerBound - 0.5) < 1e-6)

        rig.clock.advance(5)
        rig.fake.emitMine(MineMsg(kind: .partial, text: "tôi", startMs: 1000, endMs: 1400))
        rig.fake.emitMine(MineMsg(kind: .finalText, text: "tôi muốn", startMs: 1000, endMs: 2000))
        #expect(await eventually { rig.ui.lines.contains { $0.mine && $0.source == "tôi muốn" } })
        let mine = try #require(rig.ui.lines.first { $0.mine }?.audioRange)
        #expect(mine.upperBound - mine.lowerBound >= 1 - 1e-6)
    }

    @Test func losingTheBoardNotesWhen() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.board.emitState(.ready)
        #expect(await eventually { rig.ui.board == .ready })
        #expect(rig.ui.boardLostAt == nil)
        rig.clock.advance(3)
        rig.board.emitState(.scanning)
        #expect(await eventually { rig.ui.boardLostAt == rig.clock.now })
        #expect(rig.ui.boardLostBattery == nil, "the board does not report its battery: nothing is invented")
        rig.board.emitState(.connecting)
        await settle()
        #expect(rig.ui.boardLostAt == rig.clock.now, "still the moment it was lost")
        rig.board.emitState(.ready)
        #expect(await eventually { rig.ui.boardLostAt == nil })
    }

    @Test func replaySpeaksTheirLineAgainAndResendsMine() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.theirs("Hello there")
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there"] })
        let theirs = try #require(rig.ui.lines.first { !$0.mine })
        rig.ui.replayLine(theirs)
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there", "[vi]Hello there"] })

        rig.clock.advance(5)
        rig.mine("cảm ơn", final: true)
        #expect(await eventually { rig.ui.lines.first { $0.mine }?.target == "[en]cảm ơn" })
        let mine = try #require(rig.ui.lines.first { $0.mine })
        let sentBefore = rig.sent(.subtitle).count
        rig.ui.boardSubtitle = "something else"
        rig.ui.replayLine(mine)
        #expect(await eventually { rig.sent(.subtitle).count == sentBefore + 1 })
        #expect(rig.sent(.subtitle).last == "[en]cảm ơn")
        #expect(rig.ui.boardSubtitle == "[en]cảm ơn")
    }

    @Test func editReplacesTheTranslationResendsMineAndRecordsTheCorrection() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        var corrections: [(UILine, String)] = []
        rig.ui.recordCorrection = { corrections.append(($0, $1)) }

        rig.mine("Bến Thành", final: true)
        #expect(await eventually { rig.ui.lines.first { $0.mine }?.target == "[en]Bến Thành" })
        let mine = try #require(rig.ui.lines.first { $0.mine })
        rig.ui.editLine(mine, "  Ben Thanh market ")
        #expect(rig.ui.lines.first { $0.mine }?.target == "Ben Thanh market")
        #expect(await eventually { rig.sent(.subtitle).last == "Ben Thanh market" })
        #expect(rig.ui.boardSubtitle == "Ben Thanh market")
        #expect(corrections.count == 1)
        #expect(corrections.first?.0.target == "[en]Bến Thành", "the line as it was")
        #expect(corrections.first?.1 == "Ben Thanh market")

        // Empty or unchanged edits do nothing
        rig.ui.editLine(mine, "   ")
        rig.ui.editLine(try #require(rig.ui.lines.first { $0.mine }), "Ben Thanh market")
        #expect(corrections.count == 1)

        // Their line: the translation changes, nothing goes to the board
        rig.clock.advance(5)
        rig.theirs("Good morning")
        #expect(await eventually { rig.ui.lines.contains { !$0.mine } })
        let sent = rig.sent(.subtitle).count
        rig.ui.editLine(try #require(rig.ui.lines.first { !$0.mine }), "Chào buổi sáng")
        #expect(rig.ui.lines.first { !$0.mine }?.target == "Chào buổi sáng")
        await settle()
        #expect(rig.sent(.subtitle).count == sent)
        #expect(corrections.count == 2)
    }

    @Test func aLateTranslationDoesNotUndoACorrection() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.mine("một", final: true)
        #expect(await eventually { rig.ui.lines.first { $0.mine }?.target == "[en]một" })
        rig.ui.editLine(try #require(rig.ui.lines.first { $0.mine }), "one")
        // The same turn goes on (within the turn gap) and is translated again
        rig.mine("hai", final: true)
        await settle()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.ui.lines.first { $0.mine }?.target == "one")
    }

    @Test func reportGoesToTheHook() async throws {
        let ui = UIState()
        var reported: [String] = []
        ui.reportLine = { reported.append($0.id) }
        ui.reportLine(UILine(id: "t-1", mine: false, source: "a", target: "b", at: Date()))
        #expect(reported == ["t-1"])
        // The default does nothing
        UIState().reportLine(UILine(id: "x", mine: true, source: "", target: "", at: Date()))
    }

    @Test func phoneOnlyRoutesTheEngineAndHoldToTalkStartsTheConversation() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        #expect(await eventually { await rig.fake.micStates == [true] })
        // Hold is ignored outside phone-only
        rig.ui.holdToTalk(true)
        #expect(!rig.ui.talkHeld)

        rig.ui.setPhoneOnly(true)
        #expect(rig.ui.phoneOnly)
        #expect(await eventually { await rig.fake.inputModes == [.phoneOnly] })
        rig.ui.setPhoneOnly(true)   // repeated: nothing more

        rig.ui.startStop()   // stop
        #expect(await eventually { await rig.fake.micStates == [true, false] })
        #expect(!rig.ui.listening)
        rig.ui.holdToTalk(true)
        #expect(rig.ui.talkHeld)
        #expect(rig.ui.listening, "a press starts the conversation")
        #expect(await eventually { await rig.fake.talkHeld == [true] })
        #expect(await rig.fake.micStates == [true, false, true], "the mic is taken before the input moves")
        rig.ui.holdToTalk(false)
        #expect(await eventually { await rig.fake.talkHeld == [true, false] })

        rig.ui.holdToTalk(true)
        rig.ui.setPhoneOnly(false)
        #expect(!rig.ui.talkHeld, "leaving phone-only drops the hold")
        #expect(await eventually { await rig.fake.inputModes == [.phoneOnly, .board] })
    }
}
