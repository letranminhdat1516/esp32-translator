import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/model_test.dart, driven by shared/fixtures/model.json, plus Swift-only edge cases.

/// The language packs every app loads (`shared/languages`), read in place from the repository.
let languagesDirectory = Fixtures.sharedDirectory.appendingPathComponent("languages")

func packJSON(_ name: String) throws -> String {
    try String(contentsOf: languagesDirectory.appendingPathComponent("\(name).json"), encoding: .utf8)
}

private func base(_ code: String = "en") throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(packJSON(code).utf8)) as! [String: Any]
}

private func encode(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// A fixture pack case: `base` pack with the `remove` keys deleted and the `set` keys set.
private func patchedPack(_ c: [String: Any]) throws -> String {
    var m = try base(c["base"] as! String)
    for key in (c["remove"] as? [String]) ?? [] { m.removeValue(forKey: key) }
    for (key, value) in (c["set"] as? [String: Any]) ?? [:] { m[key] = value }
    return encode(m)
}

private let model = Fixtures.load("model")

@Suite struct ModelFixtureTests {
    @Test func enumNamesAndFontSetBits() {
        #expect(Script.allCases.map(\.rawValue) == model["scripts"] as! [String])
        #expect(RecognizerKind.allCases.map(\.rawValue) == model["recognizerKinds"] as! [String])
        let bits = model["fontSetBits"] as! [String: Int]
        let sets: [String: FontSets] = [
            "latinVI": .latinVI, "latinExtA": .latinExtA, "cjk": .cjk, "hangul": .hangul, "thai": .thai,
        ]
        #expect(Set(bits.keys) == Set(sets.keys))
        for (name, bit) in bits { #expect(sets[name]?.value == bit, "\(name)") }
    }

    @Test(arguments: ["vi", "en"]) func shippedPack(code: String) throws {
        let e = try #require((model["shippedPacks"] as! [String: [String: Any]])[code])
        let p = try LanguagePack.parse(packJSON(code))
        #expect(p.code == e["code"] as! String)
        #expect(p.appleLocale == e["appleLocale"] as! String)
        #expect(p.androidLocale == e["androidLocale"] as! String)
        #expect(p.whisperCode == e["whisperCode"] as! String)
        #expect(p.label == e["label"] as! String)
        #expect(p.labelLatin == e["labelLatin"] as! String)
        #expect(p.script.rawValue == e["script"] as! String)
        #expect(p.minConfidence == e["minConfidence"] as? Double)
        #expect(!p.recognition.isEmpty == e["hasRecognition"] as! Bool)
        #expect(!p.beforeTranslation.isEmpty == e["hasBeforeTranslation"] as! Bool)
        #expect(p.terms.count == e["termCount"] as! Int)
        #expect(p.hints.count == e["hintCount"] as! Int)
    }

    @Test func shippedPacksCoverEveryLanguageFile() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: languagesDirectory.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        #expect(Set(files) == Set((model["shippedPacks"] as! [String: Any]).keys))
    }

    @Test(arguments: Fixtures.cases(in: model, "packOk", fixture: "model"))
    func packOk(_ c: FixtureCase) throws {
        let j = c.json
        let p = try LanguagePack.parse(patchedPack(j))
        let e = j["expect"] as! [String: Any]
        if let script = e["script"] as? String { #expect(p.script.rawValue == script) }
        if let n = e["recognitionCount"] as? Int { #expect(p.recognition.count == n) }
        if let a = e["atClauseStart"] as? Bool { #expect(p.recognition.first?.atClauseStart == a) }
        if let origin = e["termOrigin"] as? String {
            #expect(p.terms.count == 1)
            #expect(p.terms.first?.origin.rawValue == origin)
        }
        if let hints = e["hints"] as? [String] { #expect(p.hints == hints) }
        if e.keys.contains("minConfidence") { #expect(p.minConfidence == e["minConfidence"] as? Double) }
    }

    @Test(arguments: Fixtures.cases(in: model, "packErrors", fixture: "model"))
    func packError(_ c: FixtureCase) throws {
        let j = c.json
        let json = try patchedPack(j)
        #expect { try LanguagePack.parse(json) } throws: { error in
            (error as? PackError)?.field == j["field"] as? String
        }
    }

    @Test(arguments: Fixtures.cases(in: model, "covers", fixture: "model"))
    func covers(_ c: FixtureCase) throws {
        let j = c.json
        let script = try #require(Script(rawValue: j["script"] as! String))
        let sets = FontSets(rawValue: UInt32(j["fontSets"] as! Int))
        #expect(sets.covers(script) == j["expected"] as! Bool)
    }
}

@Suite struct LanguagePackParseTests {
    /// Same field and reason as the Dart helpers (`_str`, `_opt<T>` with Dart's `$T`, `_strList`, `_objList`,
    /// `_fixedVal`): a bad list or map entry reports the list's or map's path.
    @Test(arguments: [
        (#"{"code": 5}"#, PackError(field: "code", reason: "must be a string")),
        (#"{"label": null}"#, PackError(field: "label", reason: "missing")),
        (#"{"minConfidence": "high"}"#, PackError(field: "minConfidence", reason: "must be a num")),
        (#"{"hints": ["a", 1]}"#, PackError(field: "hints", reason: "entries must be strings")),
        (#"{"hints": "a"}"#, PackError(field: "hints", reason: "must be a List<dynamic>")),
        (#"{"terms": 5}"#, PackError(field: "terms", reason: "must be a List<dynamic>")),
        (#"{"terms": [5]}"#, PackError(field: "terms[0]", reason: "must be an object")),
        (#"{"terms": [{"id": "t", "text": "x", "variants": ["a", 2]}]}"#,
         PackError(field: "terms[0].variants", reason: "entries must be strings")),
        (#"{"terms": [{"id": "t", "text": "x", "fixed": {"en": 1}}]}"#,
         PackError(field: "terms[0].fixed", reason: "values must be strings")),
        (#"{"terms": [{"id": "t", "text": "x", "fixed": "en"}]}"#,
         PackError(field: "terms[0].fixed", reason: "must be a Map<dynamic, dynamic>")),
        (#"{"terms": [{"text": "x"}]}"#, PackError(field: "terms[0].id", reason: "missing")),
        (#"{"recognition": [{"id": "r", "pattern": "a", "template": "b", "atClauseStart": "yes"}]}"#,
         PackError(field: "recognition[0].atClauseStart", reason: "must be a bool")),
        (#"{"recognition": [{"id": "r", "pattern": "a", "template": "b", "context": 1}]}"#,
         PackError(field: "recognition[0].context", reason: "must be a String")),
    ])
    func mistypedFieldThrowsDartPathAndReason(override: String, expected: PackError) throws {
        var m = try base()
        let patch = try JSONSerialization.jsonObject(with: Data(override.utf8)) as! [String: Any]
        for (k, v) in patch { m[k] = v }
        #expect(throws: expected) { try LanguagePack.parse(encode(m)) }
    }

    @Test func notJSONOrNotAnObjectThrowsAtRoot() {
        #expect { try LanguagePack.parse("{") } throws: { ($0 as? PackError)?.field == "" }
        #expect(throws: PackError(field: "", reason: "pack must be a JSON object")) { try LanguagePack.parse("[]") }
    }

    @Test func termDefaults() throws {
        var m = try base()
        m["terms"] = [["id": "t", "text": "x"]]
        let t = try #require(try LanguagePack.parse(encode(m)).terms.first)
        #expect(t.variants.isEmpty)
        #expect(t.fixed.isEmpty)
        #expect(t.origin == .user)
    }
}

@Suite struct LanguagePackRoundTripTests {
    @Test func fullPackEncodeParseEquals() throws {
        let full = try #require((model["packOk"] as! [[String: Any]]).first { $0["set"] != nil })
        let p = try LanguagePack.parse(patchedPack(full))
        let again = try LanguagePack.parse(p.jsonString())
        #expect(again == p)
        #expect(again.hashValue == p.hashValue)
    }

    @Test(arguments: ["vi", "en"]) func shippedPacksRoundTrip(name: String) throws {
        let p = try LanguagePack.parse(packJSON(name))
        #expect(try LanguagePack.parse(p.jsonString()) == p)
    }
}

@Suite struct FontSetsTests {
    @Test func unionContainsAndEquality() {
        let s = FontSets.latinVI | FontSets.thai
        #expect(s.value == 17)
        #expect(s.contains(.thai))
        #expect(!s.contains(.cjk))
        #expect(s == FontSets(rawValue: 17))
        #expect(s.hashValue == FontSets(rawValue: 17).hashValue)
    }
}

@Suite struct CapabilitiesAndBoardInfoTests {
    @Test func valueEquality() {
        func mk() -> Capabilities {
            Capabilities(recognizers: ["en": [.osOnDevice, .whisper]], translatable: ["en", "ja"], vietnameseVoice: true)
        }
        #expect(mk() == mk())
        #expect(mk().hashValue == mk().hashValue)
        #expect(mk() != Capabilities(recognizers: ["en": [.osOnline]], translatable: ["en", "ja"], vietnameseVoice: true))
        #expect(BoardInfo(protocolVersion: 1, fontSets: .latinVI) == BoardInfo(protocolVersion: 1, fontSets: .latinVI))
        #expect(BoardInfo(protocolVersion: 1, fontSets: .latinVI) != BoardInfo(protocolVersion: 2, fontSets: .latinVI))
    }
}
