import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/text_pipeline_test.dart, driven by shared/fixtures/text_pipeline.json.

private let pipelineFixture = Fixtures.load("text_pipeline")

private func pipeline(_ j: [String: Any]) throws -> TextPipeline {
    let packs = pipelineFixture["packs"] as! [String: [String: Any]]
    return try TextPipeline(
        home: Fixtures.packRef(packs[j["home"] as! String]!),
        other: Fixtures.packRef(packs[j["other"] as! String]!),
        glossary: Fixtures.terms(j["glossary"]),
        placeholders: Fixtures.stringMap(j["placeholders"]),
        defaultPlaceholder: pipelineFixture["defaultPlaceholder"] as! String)
}

private func direction(_ j: [String: Any]) -> Direction {
    j["direction"] as! String == "mine" ? .mine : .theirs
}

/// Records each request and answers with the next scripted response.
private actor ScriptedTranslator {
    private var responses: [String]
    private(set) var requests: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func translate(_ text: String) throws -> String {
        requests.append(text)
        guard !responses.isEmpty else { throw TranslatorFailed() }
        return responses.removeFirst()
    }

    struct TranslatorFailed: Error {}
}

@Suite struct TextPipelineFixtureTests {
    @Test(arguments: Fixtures.cases("text_pipeline", "prepare"))
    func prepare(_ c: FixtureCase) throws {
        let j = c.json
        let p = try pipeline(j)
        let prepared = try p.prepare(j["input"] as! String, direction(j))
        #expect(prepared.text == j["prepared"] as! String)
        for f in (j["finish"] as? [[String: Any]]) ?? [] {
            #expect(p.finish(f["translated"] as! String, prepared) == f["expected"] as? String)
        }
    }

    @Test(arguments: Fixtures.cases("text_pipeline", "translate"))
    func translate(_ c: FixtureCase) async throws {
        let j = c.json
        let p = try pipeline(j)
        let fake = ScriptedTranslator(Fixtures.strings(j["responses"]))
        let out = try await p.translate(j["input"] as! String, direction(j)) { try await fake.translate($0) }
        #expect(await fake.requests == Fixtures.strings(j["requests"]))
        #expect(out == j["expected"] as! String)
        #expect(p.lostPlaceholders == j["lostPlaceholders"] as! Int)
    }

    /// Not fixture-driven (README): an error of the translator reaches the caller.
    @Test func aTranslatorErrorPropagates() async throws {
        let p = try TextPipeline(home: Fixtures.pack("vi"), other: Fixtures.pack("en"))
        let fake = ScriptedTranslator([])
        await #expect(throws: ScriptedTranslator.TranslatorFailed.self) {
            try await p.translate("Xin chào", .mine) { try await fake.translate($0) }
        }
    }
}
