import Foundation
import Testing
@testable import TranslatorCore

/// A fake on-device model: answers with `reply` (or throws) after `delay`, records every prompt.
final class FakeRefineModel: RefineModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var _prewarms = 0
    let supported: Set<String>
    let delay: Duration
    let reply: @Sendable (String) throws -> String

    init(supported: Set<String> = ["vi", "en", "ja"], delay: Duration = .zero,
         reply: @escaping @Sendable (String) throws -> String) {
        self.supported = supported
        self.delay = delay
        self.reply = reply
    }

    var prompts: [String] { lock.withLock { _prompts } }
    var prewarms: Int { lock.withLock { _prewarms } }

    func supports(_ code: String) -> Bool { supported.contains(code) }
    func prewarm() { lock.withLock { _prewarms += 1 } }

    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try reply(prompt)
    }
}

private func request(source: String = "渋谷駅で会いましょう。", draft: String = "Hãy gặp nhau ở ga Thung lũng.",
                     from: String = "ja", to: String = "vi", context: [RefineTurn] = [],
                     terms: [RefineTerm] = []) -> RefineRequest {
    RefineRequest(source: source, draft: draft, from: from, to: to, context: context, terms: terms)
}

@Suite struct RefinePromptTests {
    @Test func promptHoldsSourceDraftLanguagesContextAndTerms() {
        let r = request(context: [RefineTurn(mine: false, source: "田中さんは来ますか？", target: "Anh Tanaka có đến không?"),
                                  RefineTurn(mine: true, source: "Có, lúc 10 giờ.", target: "はい、10時に。")],
                        terms: [RefineTerm(source: "渋谷", target: "Shibuya"), RefineTerm(source: "田中", target: "Tanaka")])
        let p = RefinePrompt.prompt(r)
        #expect(p.contains("Japanese"))
        #expect(p.contains("Vietnamese"))
        #expect(p.contains("渋谷駅で会いましょう。"))
        #expect(p.contains("Hãy gặp nhau ở ga Thung lũng."))
        #expect(p.contains("渋谷 → Shibuya"))
        #expect(p.contains("田中 → Tanaka"))
        #expect(p.contains("田中さんは来ますか？"))
        #expect(p.contains("Anh Tanaka có đến không?"))
        #expect(p.contains("Có, lúc 10 giờ."))
        // Context comes before the phrase to fix; the draft is the last thing before the answer
        let ctx = try! #require(p.range(of: "田中さんは来ますか？"))
        let src = try! #require(p.range(of: "渋谷駅で会いましょう。"))
        #expect(ctx.lowerBound < src.lowerBound)
        #expect(RefinePrompt.instructions.lowercased().contains("only"))
    }

    @Test func promptWithoutContextOrTermsHasNoEmptySections() {
        let p = RefinePrompt.prompt(request())
        #expect(!p.contains("Required terms"))
        #expect(!p.contains("Recent conversation"))
    }

    @Test func longContextLinesAreCut() {
        let long = String(repeating: "a", count: 2_000)
        let p = RefinePrompt.prompt(request(context: [RefineTurn(mine: true, source: long, target: long)]))
        #expect(p.count < 1_500)
    }

    @Test func contextIsTheLastTranslatedLinesBeforeTheLine() {
        let t0 = Date(timeIntervalSince1970: 0)
        let lines = (1...8).map { i in
            UILine(id: "t-\(i)", mine: i.isMultiple(of: 2), source: "s\(i)", target: i == 3 ? "" : "t\(i)",
                   at: t0.addingTimeInterval(Double(i)))
        } + [UILine(id: "u", mine: false, source: "noise", target: "x", unclear: true, at: t0.addingTimeInterval(7.5))]
        let ctx = RefinePrompt.context(lines, before: "t-8", limit: 3)
        #expect(ctx.map(\.source) == ["s5", "s6", "s7"])
        #expect(ctx.map(\.mine) == [false, true, false])
    }
}

@Suite struct RefineCheckTests {
    @Test func acceptsAPlausibleFixAndCleansLabelsAndQuotes() {
        let r = request()
        #expect(RefineCheck.accept("Hãy gặp nhau ở ga Shibuya.", for: r) == "Hãy gặp nhau ở ga Shibuya.")
        #expect(RefineCheck.accept("  \"Hãy gặp nhau ở ga Shibuya.\"\n", for: r) == "Hãy gặp nhau ở ga Shibuya.")
        #expect(RefineCheck.accept("Corrected translation: Hãy gặp nhau ở ga Shibuya.", for: r)
                == "Hãy gặp nhau ở ga Shibuya.")
    }

    @Test func rejectsEmpty() {
        #expect(RefineCheck.accept("", for: request()) == nil)
        #expect(RefineCheck.accept("  \"\" ", for: request()) == nil)
    }

    @Test func rejectsFarLongerThanTheDraft() {
        let rambling = "Hãy gặp nhau ở ga Shibuya. Đây là một nhà ga lớn ở Tokyo, nơi có nhiều cửa hàng và nhà hàng nổi tiếng."
        #expect(RefineCheck.accept(rambling, for: request()) == nil)
    }

    @Test func rejectsSeveralLines() {
        #expect(RefineCheck.accept("Hãy gặp nhau ở ga Shibuya.\nGhi chú: đã sửa tên ga.", for: request()) == nil)
    }

    @Test func rejectsTheWrongLanguage() {
        // A copy of the source, or the source's script, into Vietnamese
        #expect(RefineCheck.accept("渋谷駅で会いましょう。", for: request()) == nil)
        #expect(RefineCheck.accept("渋谷駅で会いましょう", for: request()) == nil)
        // English left untranslated where the draft was Vietnamese
        #expect(RefineCheck.accept("Let's meet at Shibuya station.", for: request()) == nil)
        // Into English: Vietnamese came back
        let mine = request(source: "Bát phở đặc biệt sáu mươi nghìn.", draft: "Special pho bowl sixty thousand.",
                           from: "vi", to: "en")
        #expect(RefineCheck.accept("Bát phở đặc biệt sáu mươi nghìn ạ.", for: mine) == nil)
        #expect(RefineCheck.accept("A special bowl of pho is sixty thousand dong.", for: mine)
                == "A special bowl of pho is sixty thousand dong.")
        // Into Japanese: no kana or kanji at all
        let ja = request(source: "Gặp ở ga Shibuya nhé.", draft: "渋谷駅で会いましょう。", from: "vi", to: "ja")
        #expect(RefineCheck.accept("Let's meet at Shibuya.", for: ja) == nil)
        #expect(RefineCheck.accept("渋谷駅で会おうね。", for: ja) == "渋谷駅で会おうね。")
    }

    @Test func glossaryOutputsMayKeepTheirOwnScript() {
        // A fixed term written in Vietnamese inside an English sentence is not "Vietnamese came back"
        let r = request(source: "Phở Thìn bát đặc biệt sáu mươi nghìn.", draft: "Phở Thìn special bowl sixty thousand.",
                        from: "vi", to: "en", terms: [RefineTerm(source: "Phở Thìn", target: "Phở Thìn")])
        #expect(RefineCheck.accept("A special bowl at Phở Thìn is sixty thousand.", for: r)
                == "A special bowl at Phở Thìn is sixty thousand.")
    }

    @Test func rejectsAFixThatDropsAGlossaryTermTheDraftHad() {
        let r = request(terms: [RefineTerm(source: "渋谷", target: "Shibuya")])
        let withTerm = request(draft: "Hãy gặp nhau ở ga Shibuya nhé.", terms: [RefineTerm(source: "渋谷", target: "Shibuya")])
        #expect(RefineCheck.accept("Hãy gặp nhau ở ga Thung lũng.", for: withTerm) == nil)
        #expect(RefineCheck.accept("Mình gặp nhau ở ga Shibuya nhé.", for: withTerm) == "Mình gặp nhau ở ga Shibuya nhé.")
        // The draft lost the term: the fix bringing it back is fine
        #expect(RefineCheck.accept("Hãy gặp nhau ở ga Shibuya.", for: r) == "Hãy gặp nhau ở ga Shibuya.")
    }
}

@Suite struct TranslationRefinerTests {
    @Test func returnsTheFixWhenItDiffers() async {
        let model = FakeRefineModel { _ in "Hãy gặp nhau ở ga Shibuya." }
        let refiner = TranslationRefiner(model: model)
        #expect(await refiner.refine(request()) == "Hãy gặp nhau ở ga Shibuya.")
        #expect(model.prompts.count == 1)
    }

    @Test func sameAsDraftIsNoChange() async {
        let refiner = TranslationRefiner(model: FakeRefineModel { _ in "Hãy gặp nhau ở ga Thung lũng." })
        #expect(await refiner.refine(request()) == nil)
    }

    @Test func unsupportedPairIsNotAsked() async {
        let model = FakeRefineModel(supported: ["vi", "en"]) { _ in "x" }
        let refiner = TranslationRefiner(model: model)
        #expect(!refiner.supports(from: "th", to: "vi"))
        #expect(refiner.supports(from: "en", to: "vi"))
        #expect(await refiner.refine(request(from: "th")) == nil)
        #expect(model.prompts.isEmpty)
    }

    @Test func refusalOrErrorFallsBack() async {
        struct Refused: Error {}
        let refiner = TranslationRefiner(model: FakeRefineModel { _ in throw Refused() })
        #expect(await refiner.refine(request()) == nil)
    }

    @Test func implausibleOutputFallsBack() async {
        let refiner = TranslationRefiner(model: FakeRefineModel { _ in "I'm sorry, I can't help with that request today." })
        #expect(await refiner.refine(request()) == nil)
    }

    @Test func slowModelTimesOutWithoutWaitingForIt() async {
        let model = FakeRefineModel(delay: .seconds(10)) { _ in "Hãy gặp nhau ở ga Shibuya." }
        let refiner = TranslationRefiner(model: model, timeout: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(await refiner.refine(request()) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func prewarmReachesTheModel() {
        let model = FakeRefineModel { _ in "" }
        TranslationRefiner(model: model).prewarm()
        #expect(model.prewarms == 1)
    }
}

@Suite struct RefineApplyTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func replacesTheLineThatStillShowsTheDraft() {
        let lines = [UILine(id: "t-1", mine: false, source: "a", target: "draft", at: t0)]
        #expect(RefineApply.index(of: "t-1", draft: "draft", in: lines, edited: []) == 0)
    }

    @Test func staleRefineIsIgnored() {
        // The line moved on (a newer translation), was corrected by the user, or is gone
        let lines = [UILine(id: "t-1", mine: false, source: "a", target: "newer", at: t0),
                     UILine(id: "t-2", mine: false, source: "b", target: "draft", at: t0)]
        #expect(RefineApply.index(of: "t-1", draft: "draft", in: lines, edited: []) == nil)
        #expect(RefineApply.index(of: "t-2", draft: "draft", in: lines, edited: ["t-2"]) == nil)
        #expect(RefineApply.index(of: "t-9", draft: "draft", in: lines, edited: []) == nil)
    }
}
