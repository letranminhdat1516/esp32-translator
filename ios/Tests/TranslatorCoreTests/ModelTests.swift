import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/model_test.dart.
/// The language packs every app loads, read in place from the repository (SwiftPM copies a symlinked resource
/// directory as a dangling relative link, so they are not bundled). Phase 1: point this at shared/languages.
let languagesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // TranslatorCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("shared/languages")

func packJSON(_ name: String) throws -> String {
    try String(contentsOf: languagesDirectory.appendingPathComponent("\(name).json"), encoding: .utf8)
}

private func base() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(packJSON("en").utf8)) as! [String: Any]
}

private func encode(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func packErrorField(_ json: String) -> String? {
    do {
        _ = try LanguagePack.parse(json)
        return nil
    } catch let error as PackError {
        return error.field
    } catch {
        return "unexpected \(error)"
    }
}

@Suite struct LanguagePackParseTests {
    @Test func viParses() throws {
        let p = try LanguagePack.parse(packJSON("vi"))
        #expect(p.code == "vi")
        #expect(p.appleLocale == "vi-VN")
        #expect(p.androidLocale == "vi-VN")
        #expect(p.whisperCode == "vi")
        #expect(p.label == "Tiếng Việt")
        #expect(p.labelLatin == "VI")
        #expect(p.script == .latin)
        #expect(p.minConfidence == nil)
        #expect(!p.recognition.isEmpty)
        #expect(!p.beforeTranslation.isEmpty)
        #expect(p.terms.isEmpty)
        #expect(p.hints.isEmpty)
    }

    @Test func enParses() throws {
        let p = try LanguagePack.parse(packJSON("en"))
        #expect(p.code == "en")
        #expect(p.appleLocale == "en-US")
        #expect(p.androidLocale == "en-US")
        #expect(p.whisperCode == "en")
        #expect(p.label == "English")
        #expect(p.labelLatin == "EN")
        #expect(p.minConfidence == 0.4)
    }

    @Test func missingLabelThrowsPackErrorLabel() throws {
        var m = try base()
        m.removeValue(forKey: "label")
        #expect(packErrorField(encode(m)) == "label")
    }

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

    @Test func invalidRecognitionPatternThrowsWithPath() throws {
        var m = try base()
        m["recognition"] = [["id": "r", "pattern": "(", "template": "x"]]
        #expect(packErrorField(encode(m)) == "recognition[0].pattern")
    }

    @Test func invalidBeforeTranslationContextThrowsWithPath() throws {
        var m = try base()
        m["beforeTranslation"] = [
            ["id": "a", "pattern": "a", "template": "b"],
            ["id": "r", "pattern": "a", "template": "b", "context": "["],
        ]
        #expect(packErrorField(encode(m)) == "beforeTranslation[1].context")
    }

    @Test func unknownScriptThrowsPackErrorScript() throws {
        var m = try base()
        m["script"] = "klingon"
        #expect(packErrorField(encode(m)) == "script")
    }

    @Test func unknownTermOriginThrowsWithPath() throws {
        var m = try base()
        m["terms"] = [["id": "t", "text": "x", "origin": "alien"]]
        #expect(packErrorField(encode(m)) == "terms[0].origin")
    }

    @Test func notJSONOrNotAnObjectThrowsAtRoot() {
        #expect(packErrorField("{") == "")
        #expect(packErrorField("[]") == "")
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
        var m = try base()
        m["script"] = "cjk"
        m["recognition"] = [[
            "id": "r1", "pattern": #"\bfoo\b"#, "template": "bar", "atClauseStart": true, "context": "baz",
        ]]
        m["beforeTranslation"] = [["id": "b1", "pattern": "x", "template": "y"]]
        m["terms"] = [[
            "id": "t1", "text": "Tuan", "variants": ["Tuấn", "Toan"], "fixed": ["en": "Tuan"], "origin": "user",
        ]]
        m["hints"] = ["a", "b"]
        let p = try LanguagePack.parse(encode(m))
        let again = try LanguagePack.parse(p.jsonString())
        #expect(again == p)
        #expect(again.hashValue == p.hashValue)
        #expect(again.recognition.first?.atClauseStart == true)
        #expect(again.terms.first?.origin == .user)
        #expect(again.script == .cjk)
    }

    @Test(arguments: ["vi", "en"]) func shippedPacksRoundTrip(name: String) throws {
        let p = try LanguagePack.parse(packJSON(name))
        #expect(try LanguagePack.parse(p.jsonString()) == p)
    }
}

@Suite struct FontSetsTests {
    @Test func bitValues() {
        #expect(FontSets.latinVI.value == 1)
        #expect(FontSets.latinExtA.value == 2)
        #expect(FontSets.cjk.value == 4)
        #expect(FontSets.hangul.value == 8)
        #expect(FontSets.thai.value == 16)
    }

    @Test func latinVIDoesNotCoverCJK() {
        #expect(!FontSets.latinVI.covers(.cjk))
    }

    @Test func coversMapping() {
        #expect(FontSets.latinVI.covers(.latin))
        #expect(FontSets.latinExtA.covers(.latin))
        #expect(!FontSets.cjk.covers(.latin))
        #expect(FontSets.cjk.covers(.cjk))
        #expect(FontSets.hangul.covers(.hangul))
        #expect(FontSets.thai.covers(.thai))
        let all = FontSets(rawValue: 31)
        #expect(!all.covers(.cyrillic))
        #expect(!all.covers(.other))
    }

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
