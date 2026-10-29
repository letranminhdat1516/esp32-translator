import Foundation
import Testing
@testable import TermHarnessKit

// Driven by shared/fixtures/terms/harness.json, the same cases android/__tests__/termHarness.test.ts passes; plus
// the corpus (shared/fixtures/terms/<lang>.tsv) checked for shape and size.

private let sharedDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("shared")
private let fixture: [String: Any] = {
    let data = try! Data(contentsOf: sharedDir.appendingPathComponent("fixtures/terms/harness.json"))
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}()

struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    nonisolated(unsafe) let json: [String: Any]
    var testDescription: String { name }
}

private func cases(_ group: String) -> [Case] {
    (fixture[group] as! [[String: Any]]).map { Case(name: $0["name"] as? String ?? $0["input"] as! String, json: $0) }
}

private final class Asked: @unchecked Sendable { var texts: [String] = [] }

@Suite struct TermHarnessFixtureTests {
    @Test func shapesAreTheFixtureList() {
        #expect(Harness.shapes == fixture["shapes"] as! [String])
    }

    @Test(arguments: cases("parse"))
    func parse(_ c: Case) throws {
        let j = c.json
        let lang = j["lang"] as! String
        if let e = j["error"] as? [String: Any] {
            do {
                _ = try Harness.parseCorpus(j["text"] as! String, lang: lang)
                Issue.record("expected an error")
            } catch let error as CorpusError {
                #expect(error.kind.rawValue == e["kind"] as! String)
                #expect(error.lineNo == e["lineNo"] as! Int)
            }
            return
        }
        let lines = try Harness.parseCorpus(j["text"] as! String, lang: lang)
        let expected = (j["expected"] as! [[String: Any]]).map {
            CorpusLine(lang: lang, from: $0["from"] as! String, to: $0["to"] as! String, source: $0["source"] as! String,
                       term: $0["term"] as! String, expected: $0["expected"] as! String, lineNo: $0["lineNo"] as! Int)
        }
        #expect(lines == expected)
    }

    @Test(arguments: cases("evaluate"))
    func evaluate(_ c: Case) async throws {
        let j = c.json
        let line = try Harness.parseCorpus(j["line"] as! String, lang: j["lang"] as! String)[0]
        let translations = j["translations"] as! [String: String]
        let asked = Asked()
        let translate: (String) async throws -> String = { text in
            asked.texts.append(text)
            guard let out = translations[text] else { throw TestError(message: "unexpected request \(text)") }
            return out
        }
        if let error = j["error"] as? String {
            #expect(error == "termNotFound")
            await #expect(throws: TermNotFound.self) {
                _ = try await Harness.evaluate(line, shape: j["shape"] as! String, translate: translate)
            }
            return
        }
        let o = try await Harness.evaluate(line, shape: j["shape"] as! String, translate: translate)
        let e = j["expected"] as! [String: Any]
        #expect(o.masked == j["masked"] as! String)
        #expect(asked.texts == e["asked"] as! [String])
        #expect(o.restored == e["restored"] as! Bool)
        #expect(o.output == e["output"] as! String)
        #expect(o.passed == e["passed"] as! Bool)
    }

    @Test(arguments: cases("scripted"))
    func scripted(_ c: Case) {
        #expect(Harness.scripted(c.json["input"] as! String) == c.json["output"] as! String)
    }

    @Test(arguments: cases("report"))
    func report(_ c: Case) {
        let j = c.json
        let results = (j["results"] as! [[String: Any]]).map {
            HarnessResult(lang: $0["lang"] as! String, from: $0["from"] as! String, to: $0["to"] as! String,
                          shape: $0["shape"] as! String, restored: $0["restored"] as! Bool, passed: $0["passed"] as! Bool)
        }
        let shapes = j["shapes"] as! [String]
        let best = Harness.bestShapes(results, shapes: shapes)
        let expected = j["best"] as! [String: [String: Any]]
        #expect(Set(best.map(\.lang)) == Set(expected.keys))
        for (lang, b) in best {
            let e = expected[lang]!
            #expect(b == Best(shape: e["shape"] as! String, passed: e["passed"] as! Int, total: e["total"] as! Int,
                              lost: e["lost"] as! Int))
        }
        #expect(Harness.report(results, shapes: shapes, engine: j["engine"] as! String) == j["markdown"] as! String)
    }

    @Test(arguments: cases("setPlaceholder"))
    func setPlaceholder(_ c: Case) throws {
        let j = c.json
        let run = { try Harness.setPlaceholder(j["text"] as! String, key: j["key"] as! String, shape: j["shape"] as! String) }
        if j["error"] != nil {
            #expect(throws: HarnessError.self) { _ = try run() }
            return
        }
        #expect(try run() == j["expected"] as! String)
    }
}

@Suite struct TermHarnessRunTests {
    @Test func runCorpusTriesEveryShapeAndCountsTranslatorErrorsAsFailures() async throws {
        let lines = try Harness.parseCorpus(
            "en>vi\tI booked a Grab to the airport.\tGrab\tGrab\nvi>en\tTàu từ Hà Nội vào Huế.\tHà Nội\tHanoi", lang: "en")
        let asked = Asked()
        let (results, errors) = try await Harness.runCorpus(lines, shapes: ["Zorvik{n}", "[[{n}]]"]) { text, from, to in
            asked.texts.append("\(from)>\(to) \(text)")
            if text.contains("[[") { throw TestError(message: "boom") }
            return Harness.scripted(text)
        }
        #expect(results == [
            HarnessResult(lang: "en", from: "en", to: "vi", shape: "Zorvik{n}", restored: true, passed: true),
            HarnessResult(lang: "en", from: "en", to: "vi", shape: "[[{n}]]", restored: false, passed: false),
            HarnessResult(lang: "en", from: "vi", to: "en", shape: "Zorvik{n}", restored: true, passed: true),
            HarnessResult(lang: "en", from: "vi", to: "en", shape: "[[{n}]]", restored: false, passed: false),
        ])
        #expect(errors.count == 2 && errors[0].hasPrefix("en:1 [[{n}]]: "))
        #expect(asked.texts[2] == "vi>en Tàu từ Zorvik1 vào Huế.")
    }
}

@Suite struct CorpusTests {
    static let dir = sharedDir.appendingPathComponent("fixtures/terms")
    static let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
        .filter { $0.hasSuffix(".tsv") }.sorted() ?? []

    @Test func hasEveryLanguageOfThePlan() {
        #expect(Self.files == ["de.tsv", "en.tsv", "es.tsv", "fr.tsv", "ja.tsv", "ko.tsv", "th.tsv", "zh-Hans.tsv"])
    }

    @Test(arguments: files)
    func everyTermIsMaskedByEveryShape(_ file: String) throws {
        let lang = String(file.dropLast(4))
        let text = try String(contentsOf: Self.dir.appendingPathComponent(file), encoding: .utf8)
        let lines = try Harness.parseCorpus(text, lang: lang)
        #expect(lines.filter { $0.to == "vi" }.count >= 40)
        #expect(lines.filter { $0.from == "vi" }.count >= 40)
        var unmasked: [String] = []
        for line in lines {
            for shape in Harness.shapes where try Harness.mask(line, shape: shape).isEmpty {
                unmasked.append("\(line.lineNo) \(shape)")
            }
        }
        #expect(unmasked == [])
    }
}

private struct TestError: Error { let message: String }
