import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/rule_engine_test.dart, driven by shared/fixtures/rules.json.

private let rulesFixture = Fixtures.load("rules")

private func rules(_ v: Any?) -> [Rule] {
    ((v as? [[String: Any]]) ?? []).map {
        Rule(id: $0["id"] as! String, pattern: $0["pattern"] as! String, template: $0["template"] as! String,
             atClauseStart: $0["atClauseStart"] as? Bool ?? false, context: $0["context"] as? String)
    }
}

private func engine(_ id: String) throws -> RuleEngine {
    let engines = rulesFixture["engines"] as! [String: [String: Any]]
    let spec = try #require(engines[id], "unknown engine \(id)")
    if let code = spec["pack"] as? String { return try RuleEngine(pack: Fixtures.pack(code)) }
    return try RuleEngine(recognition: rules(spec["recognition"]), beforeTranslation: rules(spec["beforeTranslation"]))
}

/// Every pack in shared/languages.
private func bundledPackCodes() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: Fixtures.sharedDirectory.appendingPathComponent("languages").path)
        .filter { $0.hasSuffix(".json") }
        .map { String($0.dropLast(5)) }
        .sorted()
}

/// True when `pattern` has a lookbehind whose body can match text of unbounded length (an unescaped `*`, `+` or
/// `{n,}`), which ICU rejects. Port of `_unboundedLookbehind` in rule_engine_test.dart.
private func unboundedLookbehind(_ pattern: String) -> Bool {
    let chars = Array(pattern)
    let opener = try! NSRegularExpression(pattern: "\\(\\?<[=!]")
    let unbounded = try! NSRegularExpression(pattern: "[*+]|\\{[0-9]*,\\}")
    let ns = pattern as NSString
    for start in opener.matches(in: pattern, range: NSRange(location: 0, length: ns.length)) {
        // The opener is ASCII, so its UTF-16 end is a Character offset into the prefix.
        var i = ns.substring(to: NSMaxRange(start.range)).count
        var depth = 1
        var body = ""
        while i < chars.count && depth > 0 {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                body += "  "  // an escaped character never counts
                i += 2
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth > 0 { body.append(c) }
            i += 1
        }
        if unbounded.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { return true }
    }
    return false
}

@Suite struct RuleEngineFixtureTests {
    @Test(arguments: Fixtures.cases("rules", "cases"))
    func ruleCase(_ c: FixtureCase) throws {
        let j = c.json
        let e = try engine(j["engine"] as! String)
        let input = j["input"] as! String
        let out: String
        switch j["fn"] as! String {
        case "fixRecognition": out = e.fixRecognition(input)
        case "forTranslation": out = e.forTranslation(input)
        case let fn: Issue.record("unknown fn \(fn)"); return
        }
        #expect(out == j["expected"] as! String)
    }
}

@Suite struct RuleEnginePortableSyntaxTests {
    private let syntax = rulesFixture["portableSyntax"] as! [String: Any]

    private var forbidden: [(String, NSRegularExpression)] {
        Fixtures.cases(in: syntax, "forbidden").map {
            ($0.name, try! NSRegularExpression(pattern: $0.json["regex"] as! String))
        }
    }

    private func violations(_ s: String) -> [String] {
        forbidden.filter { $0.1.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }.map(\.0)
    }

    @Test func forbiddenListCatchesWhatItNames() {
        for (s, name) in [("a++", "possessive quantifier"), ("(?>a)", "atomic group"), ("(?i)a", "inline flags"),
                          ("(?<x>a)", "named group or backreference"), ("a\\z", "anchors and escapes missing in JS"),
                          ("[[:alpha:]]", "POSIX class"),
                          ("\\p{Lu}", "Unicode class other than \\p{L}, \\p{N}, \\p{M}")] {
            #expect(violations(s).contains(name), "\(s)")
        }
        let classes = "\\D \\w \\W \\b \\B (ASCII in one engine, Unicode in another)"
        for (s, name) in [("a\\Db", classes), ("\\w+", classes), ("x\\W", classes), ("\\bok\\b", classes),
                          ("\\Bk", classes), ("[a[b]]", "nested class"), ("[^,[]", "nested class"),
                          ("[a-z&&[^x]]", "class intersection &&")] {
            #expect(violations(s).contains(name), "\(s)")
        }
        // Escapes and plain text that only look like them
        for s in ["\\\\D", "\\[a[b]", "[\\[]", "a&&b", "[\\d.,]", "(?:x|y)\\s*$"] {
            #expect(violations(s).isEmpty, "\(s): \(violations(s))")
        }
        #expect(violations("(?<=xe )(?:a|b)*?\\d{3,}[\\d.,]+\\p{L}").isEmpty)
        #expect(unboundedLookbehind("(?<=a+)b"))
        #expect(!unboundedLookbehind("(?<!(?:x|yz) )b"))
    }

    @Test func bundledPacksUseThePortableSubset() throws {
        #expect(syntax["digits"] as? String == "ascii")
        #expect(syntax["lookbehind"] as? String == "bounded")
        let codes = try bundledPackCodes()
        #expect(!codes.isEmpty)
        for code in codes {
            let pack = try Fixtures.pack(code)
            for r in pack.recognition + pack.beforeTranslation {
                for p in [r.pattern] + (r.context.map { [$0] } ?? []) {
                    #expect(violations(p).isEmpty, "\(code) \(r.id): \(violations(p)) in \(p)")
                    #expect(!unboundedLookbehind(p), "\(code) \(r.id): unbounded lookbehind in \(p)")
                }
            }
        }
    }

    @Test func everyBundledRuleHasAUniqueId() throws {
        for code in try bundledPackCodes() {
            let pack = try Fixtures.pack(code)
            let ids = (pack.recognition + pack.beforeTranslation).map(\.id)
            #expect(Set(ids).count == ids.count, "\(code)")
            #expect(ids.allSatisfy { !$0.isEmpty }, "\(code)")
        }
    }

    @Test(arguments: [
        ("\\d", "[0-9]"), ("[\\d.,]", "[0-9.,]"), ("\\d+[.,]\\d{3}", "[0-9]+[.,][0-9]{3}"),
        ("\\\\d", "\\\\d"), ("a\\.d", "a\\.d"), ("[^\\d]", "[^0-9]"), ("[\\]\\d]", "[\\]0-9]"),
        ("\\D", "[^0-9]"), ("a\\D+b", "a[^0-9]+b"), ("\\\\D", "\\\\D"),
    ])
    func asciiDigitsRewrite(pattern: String, expected: String) {
        #expect(RuleEngine.portablePattern(pattern) == expected)
    }
}

@Suite struct RuleEngineAdversarialTests {
    private let adversarial = rulesFixture["adversarial"] as! [String: Any]

    private var subjects: [(String, String)] {
        let minLength = adversarial["minLength"] as! Int
        return Fixtures.cases(in: adversarial, "subjects").map { c in
            let j = c.json
            var s = j["prefix"] as! String
            let unit = j["unit"] as! String
            // Length as in Dart: UTF-16 code units
            while s.utf16.count < minLength { s += unit }
            return (c.name, s)
        }
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func everyViRuleIsFastOnAdversarialText() throws {
        let limit = Double(adversarial["maxMsPerRule"] as! Int)
        let engine = try RuleEngine(pack: Fixtures.pack("vi"))
        let all = engine.recognitionRules + engine.beforeRules
        #expect(!all.isEmpty)
        for rule in all {
            for (name, text) in subjects {
                let ms = milliseconds {
                    let range = NSRange(location: 0, length: (text as NSString).length)
                    _ = rule.context?.firstMatch(in: text, range: range)
                    _ = rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                }
                #expect(ms < limit, "\(rule.id) on \(name) took \(ms) ms")
            }
        }
    }

    @Test func theWholePipelineIsFastToo() throws {
        let limit = Double(adversarial["maxMsPipeline"] as! Int)
        let engine = try RuleEngine(pack: Fixtures.pack("vi"))
        for (name, text) in subjects {
            let ms = milliseconds { _ = engine.forTranslation(text) }
            #expect(ms < limit, "forTranslation on \(name) took \(ms) ms")
        }
    }
}
