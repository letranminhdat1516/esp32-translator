import Foundation

// Term harness (P2.5, R10): corpus, scoring, report and pack update, all pure; cases in
// shared/fixtures/terms/harness.json. Format and scoring rule:
// shared/fixtures/terms/README.md. TermProtector, Term and the Unicode helpers are the app's own files (Linked/).

/// One corpus sentence: translate `source` from `from` to `to`; `expected` must be in the output.
public struct CorpusLine: Hashable, Sendable {
    /// The file's language (the pair is this language and vi).
    public let lang: String
    public let from: String
    public let to: String
    public let source: String
    public let term: String
    /// The term verbatim, or its fixed translation for `to`.
    public let expected: String
    /// 1-based line number in the file.
    public let lineNo: Int
}

/// A corpus line that is not `direction<TAB>source<TAB>term<TAB>expected`.
public struct CorpusError: Error, CustomStringConvertible {
    public enum Kind: String, Sendable { case columns, direction, empty }
    public let kind: Kind
    public let lineNo: Int
    public let detail: String
    public var description: String { "line \(lineNo): \(detail)" }
}

/// The term of a line is not found (masked) in its source sentence.
public struct TermNotFound: Error, CustomStringConvertible {
    public let line: CorpusLine
    public var description: String { "line \(line.lineNo): term \"\(line.term)\" is not masked in \"\(line.source)\"" }
}

public struct HarnessError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public struct Outcome: Sendable {
    /// The text sent to the translator first.
    public let masked: String
    /// The placeholders survived (no fallback).
    public let restored: Bool
    /// What the app would show.
    public let output: String
    public let passed: Bool
}

/// One line × one shape.
public struct HarnessResult: Hashable, Sendable {
    public let lang: String
    public let from: String
    public let to: String
    public let shape: String
    public let restored: Bool
    public let passed: Bool

    public init(lang: String, from: String, to: String, shape: String, restored: Bool, passed: Bool) {
        (self.lang, self.from, self.to, self.shape, self.restored, self.passed) = (lang, from, to, shape, restored, passed)
    }
}

public struct Best: Hashable, Sendable {
    public let shape: String
    public let passed: Int
    public let total: Int
    public let lost: Int
}

/// What the harness translates with: Apple Translation in the real run, a fake for the smoke test.
public protocol Translating: Sendable {
    /// Translates `text` from `from` to `to` (catalog codes).
    func translate(_ text: String, from: String, to: String) async throws -> String
}

/// The Mac smoke test: `identity` returns the text, `scripted` applies `Harness.scripted`.
public struct FakeTranslator: Translating {
    public enum Mode: String, Sendable { case identity, scripted }
    public let mode: Mode
    public init(_ mode: Mode) { self.mode = mode }
    public func translate(_ text: String, from: String, to: String) async throws -> String {
        mode == .identity ? text : Harness.scripted(text)
    }
}

public enum Harness {
    /// Placeholder shapes tried, in tie-break order.
    public static let shapes = ["Zorvik{n}", "[[{n}]]", "TERM{n}", "⟦{n}⟧", "__{n}__"]

    /// The R10 target in tenths of a percent.
    static let targetTenths = 950

    private static let protector = TermProtector()

    /// Parses a corpus file of language `lang`. Blank lines and lines starting with `#` are skipped; a trailing CR is
    /// dropped. Throws `CorpusError`.
    public static func parseCorpus(_ text: String, lang: String) throws -> [CorpusLine] {
        var out: [CorpusLine] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let lineNo = i + 1
            let row = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if row.trimmingCharacters(in: .whitespaces).isEmpty || row.hasPrefix("#") { continue }
            let cols = row.components(separatedBy: "\t")
            guard cols.count == 4 else {
                throw CorpusError(kind: .columns, lineNo: lineNo, detail: "\(cols.count) columns, expected 4")
            }
            let pair = cols[0].components(separatedBy: ">")
            guard pair.count == 2, (pair[0] == lang && pair[1] == "vi") || (pair[0] == "vi" && pair[1] == lang) else {
                throw CorpusError(kind: .direction, lineNo: lineNo,
                                  detail: "direction \"\(cols[0])\" is not \(lang)>vi or vi>\(lang)")
            }
            guard !cols[1].isEmpty, !cols[2].isEmpty, !cols[3].isEmpty else {
                throw CorpusError(kind: .empty, lineNo: lineNo, detail: "empty field")
            }
            out.append(CorpusLine(lang: lang, from: pair[0], to: pair[1], source: cols[1], term: cols[2],
                                  expected: cols[3], lineNo: lineNo))
        }
        return out
    }

    /// The protected term of a line: the term, with `expected` as its fixed translation when it differs.
    static func term(of line: CorpusLine) -> Term {
        Term(id: line.term, text: line.term, fixed: line.expected == line.term ? [:] : [line.to: line.expected])
    }

    static func mask(_ line: CorpusLine, shape: String) throws -> Masked {
        try protector.mask(line.source, terms: [term(of: line)], target: line.to, placeholder: shape)
    }

    /// True when `output` holds `expected` (both NFC, exact case, anywhere; compared in UTF-16 like the TS twin).
    public static func passes(_ output: String, _ expected: String) -> Bool {
        (output.nfc as NSString).range(of: expected.nfc, options: .literal).location != NSNotFound
    }

    /// Runs one line through the app's term path with `shape`: mask, translate, restore; when a placeholder is lost,
    /// translate the plain source and repair fixed terms (TextPipeline.repair). Throws `TermNotFound` when the term is
    /// not masked.
    public static func evaluate(_ line: CorpusLine, shape: String,
                                translate: (String) async throws -> String) async throws -> Outcome {
        let m = try mask(line, shape: shape)
        if m.isEmpty { throw TermNotFound(line: line) }
        if let restored = protector.restore(try await translate(m.text), m) {
            return Outcome(masked: m.text, restored: true, output: restored, passed: passes(restored, line.expected))
        }
        var output = try await translate(line.source)
        for (surface, replacement) in m.replacements where surface != replacement {
            output = TermProtector.wholeWordRegex(surface, caseSensitive: true).replacingMatches(in: output) { _ in
                replacement
            }
        }
        return Outcome(masked: m.text, restored: false, output: output, passed: passes(output, line.expected))
    }

    /// The scripted fake translator: `[[`/`]]` and `__` halved, so the bracket and underscore shapes lose their
    /// placeholders and the others keep them.
    public static func scripted(_ text: String) -> String {
        text.replacingOccurrences(of: "[[", with: "[").replacingOccurrences(of: "]]", with: "]")
            .replacingOccurrences(of: "__", with: "_")
    }

    /// Every line with every shape. A translator error fails that line × shape (not restored, not passed) and is
    /// listed in `errors`; a term that is not masked throws `TermNotFound`.
    public static func runCorpus(_ lines: [CorpusLine], shapes: [String],
                                 translate: (String, String, String) async throws -> String) async throws
        -> (results: [HarnessResult], errors: [String]) {
        var results: [HarnessResult] = []
        var errors: [String] = []
        for line in lines {
            for shape in shapes {
                do {
                    let o = try await evaluate(line, shape: shape) { try await translate($0, line.from, line.to) }
                    results.append(HarnessResult(lang: line.lang, from: line.from, to: line.to, shape: shape,
                                                 restored: o.restored, passed: o.passed))
                } catch let e as TermNotFound {
                    throw e
                } catch {
                    errors.append("\(line.lang):\(line.lineNo) \(shape): \(error)")
                    results.append(HarnessResult(lang: line.lang, from: line.from, to: line.to, shape: shape,
                                                 restored: false, passed: false))
                }
            }
        }
        return (results, errors)
    }

    private static func tally(_ results: [HarnessResult]) -> (passed: Int, total: Int, lost: Int) {
        (results.filter(\.passed).count, results.count, results.filter { !$0.restored }.count)
    }

    private static func languages(_ results: [HarnessResult]) -> [String] {
        var seen = Set<String>()
        return results.map(\.lang).filter { seen.insert($0).inserted }
    }

    /// Best shape per language (in order of first appearance): most passes over both directions, then fewest lost
    /// placeholders, then the earlier shape in `shapes`.
    public static func bestShapes(_ results: [HarnessResult], shapes: [String]) -> [(lang: String, best: Best)] {
        languages(results).compactMap { lang in
            var top: Best?
            for shape in shapes {
                let t = tally(results.filter { $0.lang == lang && $0.shape == shape })
                if t.total == 0 { continue }
                if top == nil || t.passed > top!.passed || (t.passed == top!.passed && t.lost < top!.lost) {
                    top = Best(shape: shape, passed: t.passed, total: t.total, lost: t.lost)
                }
            }
            return top.map { (lang, $0) }
        }
    }

    /// passed/total in tenths of a percent, rounded half up.
    private static func tenths(_ passed: Int, _ total: Int) -> Int { (passed * 2000 + total) / (2 * total) }

    private static func percent(_ t: Int) -> String { "\(t / 10).\(t % 10) %" }

    /// The Markdown report: one row per language and direction (plus both), one column per shape; then the best shapes.
    public static func report(_ results: [HarnessResult], shapes: [String], engine: String) -> String {
        var rows = [
            "## Term accuracy: \(engine)",
            "",
            "| Language | Direction | \(shapes.map { "`\($0)`" }.joined(separator: " | ")) |",
            "|---|---|\(String(repeating: "---:|", count: shapes.count))",
        ]
        for lang in languages(results) {
            let of = results.filter { $0.lang == lang }
            let groups = [("\(lang) → vi", of.filter { $0.to == "vi" }), ("vi → \(lang)", of.filter { $0.from == "vi" }),
                          ("both", of)]
            for (label, group) in groups {
                let count = shapes.map { s in group.filter { $0.shape == s }.count }.max() ?? 0
                let cells = shapes.map { s -> String in
                    let t = tally(group.filter { $0.shape == s })
                    return t.total == 0 ? "—" : "\(percent(tenths(t.passed, t.total))) · \(t.lost) lost"
                }
                rows.append("| \(lang) | \(label) (\(count)) | \(cells.joined(separator: " | ")) |")
            }
        }
        rows += ["", "| Language | Best shape | Accuracy | Lost placeholders | R10 (≥ 95 %) |", "|---|---|---:|---:|---|"]
        for (lang, b) in bestShapes(results, shapes: shapes) {
            let t = tenths(b.passed, b.total)
            let verdict = t >= targetTenths ? "yes" : "no (\(percent(targetTenths - t).dropLast(2)) points short)"
            rows.append("| \(lang) | `\(b.shape)` | \(percent(t)) | \(b.lost) | \(verdict) |")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Sets the top-level string `key` of a pack file to `shape`, keeping the rest of the text as is: replaces the value
    /// of an existing `"key": ...` line, or inserts the line after `"appleLocale"`.
    public static func setPlaceholder(_ packText: String, key: String, shape: String) throws -> String {
        if shape.contains(where: { $0 == "\"" || $0 == "\\" || $0 == "\n" }) {
            throw HarnessError(description: "placeholder \(shape) cannot be written")
        }
        var lines = packText.components(separatedBy: "\n")
        func split(_ l: String) -> (indent: String, rest: Substring) {
            let indent = l.prefix { $0 == " " || $0 == "\t" }
            return (String(indent), l.dropFirst(indent.count))
        }
        if let i = lines.firstIndex(where: { split($0).rest.hasPrefix("\"\(key)\":") }) {
            let (indent, rest) = split(lines[i])
            let comma = rest.trimmingCharacters(in: .whitespaces).hasSuffix(",") ? "," : ""
            lines[i] = "\(indent)\"\(key)\": \"\(shape)\"\(comma)"
            return lines.joined(separator: "\n")
        }
        guard let a = lines.firstIndex(where: { split($0).rest.hasPrefix("\"appleLocale\":") }) else {
            throw HarnessError(description: "no \"appleLocale\" line to insert the placeholder after")
        }
        lines.insert("\(split(lines[a]).indent)\"\(key)\": \"\(shape)\",", at: a + 1)
        return lines.joined(separator: "\n")
    }
}
