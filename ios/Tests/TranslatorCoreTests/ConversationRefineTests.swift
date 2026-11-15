import Foundation
import Testing
@testable import TranslatorCore

/// The refine step in the conversation: the draft is shown and spoken at once, the model's fix replaces the line
/// (and the board subtitle for my line) later, and a fix for a line that moved on is dropped.
@Suite(.serialized) @MainActor
struct ConversationRefineTests {
    /// Replies with `fix` for any prompt whose phrase to fix contains `when` (the "Source:" line).
    private static func model(delay: Duration = .zero, _ fixes: [String: String]) -> FakeRefineModel {
        FakeRefineModel(supported: ["vi", "en", "ja"], delay: delay) { prompt in
            let source = prompt.components(separatedBy: "\n").last { $0.hasPrefix("Source: ") } ?? ""
            for (when, fix) in fixes where source.contains(when) { return fix }
            return ""
        }
    }

    @Test func theirLineIsReplacedAfterTheDraftWasSpoken() async throws {
        let model = Self.model(delay: .milliseconds(150), ["Hello there": "Xin chào bạn"])
        let rig = try await Rig(refiner: TranslationRefiner(model: model))
        #expect(await rig.startRunning())
        rig.theirs("Hello there")
        // The draft is spoken without waiting for the model
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there"] })
        #expect(rig.ui.lines.contains { !$0.mine && $0.target == "[vi]Hello there" })
        #expect(await eventually { rig.ui.lines.contains { !$0.mine && $0.target == "Xin chào bạn" } })
        #expect(rig.ui.lines.filter { !$0.mine }.count == 1)
        #expect(await rig.spoken() == ["[vi]Hello there"])
        rig.controller.shutdown()
    }

    @Test func myLineAndBoardSubtitleAreReplaced() async throws {
        let model = Self.model(["tôi muốn đi chợ": "I want to go to the market"])
        let rig = try await Rig(refiner: TranslationRefiner(model: model))
        #expect(await rig.startRunning())
        rig.mine("tôi muốn đi chợ", final: true)
        #expect(await eventually { rig.ui.lines.contains { $0.mine && $0.target == "I want to go to the market" } })
        #expect(await eventually { rig.sent(.subtitle).last == "I want to go to the market" })
        #expect(rig.sent(.subtitle).contains("[en]tôi muốn đi chợ"))
        rig.controller.shutdown()
    }

    @Test func promptCarriesTheConversationAndGlossaryTerms() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = Self.model([:])
        let rig = try await Rig(glossaryDirectory: dir, refiner: TranslationRefiner(model: model))
        #expect(await rig.startRunning())
        try rig.ui.glossaryAdd("Shinjuku")
        #expect(await eventually { rig.ui.glossaryTerms.map(\.text) == ["Shinjuku"] })
        rig.theirs("Where are you going")
        #expect(await eventually { model.prompts.count == 1 })
        rig.clock.advance(1)
        rig.theirs("Meet me at Shinjuku")
        #expect(await eventually { model.prompts.count == 2 })
        let prompt = try #require(model.prompts.last)
        #expect(prompt.contains("Them (English): Where are you going = [vi]Where are you going"))
        #expect(prompt.contains("Shinjuku → Shinjuku"))
        #expect(prompt.contains("Source: Meet me at Shinjuku"))
        rig.controller.shutdown()
    }

    @Test func correctedLineIsNotOverwrittenByALateFix() async throws {
        let model = Self.model(delay: .milliseconds(150), ["Hello there": "Xin chào bạn"])
        let rig = try await Rig(refiner: TranslationRefiner(model: model))
        #expect(await rig.startRunning())
        rig.theirs("Hello there")
        #expect(await eventually { rig.ui.lines.contains { !$0.mine && $0.target == "[vi]Hello there" } })
        let line = try #require(rig.ui.lines.first { !$0.mine })
        rig.ui.editLine(line, "Chào anh")
        #expect(await eventually { model.prompts.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.ui.lines.first { !$0.mine }?.target == "Chào anh")
        rig.controller.shutdown()
    }

    @Test func noRefinerKeepsTheDraft() async throws {
        let rig = try await Rig()
        #expect(await rig.startRunning())
        rig.theirs("Hello there")
        #expect(await eventually { await rig.spoken() == ["[vi]Hello there"] })
        await settle()
        #expect(rig.ui.lines.first { !$0.mine }?.target == "[vi]Hello there")
        rig.controller.shutdown()
    }
}
