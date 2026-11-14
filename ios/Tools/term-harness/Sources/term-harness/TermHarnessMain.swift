import Foundation
import TermHarnessKit

// Term harness (P2.5, R10), Apple side. Every line of shared/fixtures/terms/<lang>.tsv is masked by the app's own
// TermProtector with each placeholder shape, translated, restored (or translated plain and repaired, as the app's
// TextPipeline does when a placeholder is lost) and scored; prints the Markdown table and the best shape per language.
//
//   swift run term-harness --fake                   # smoke test on the Mac: identity translator
//   swift run term-harness --fake scripted          # fake that breaks the [[n]] and __n__ shapes
//   swift run term-harness --lang en,ja             # Apple Translation (languages must be installed)
//   swift run term-harness --out results.md         # also write the table to a file
//   swift run term-harness --write-packs            # real run only: best shape -> shared/languages/<lang>.json
//                                                     ("applePlaceholder"); off by default
//
// Options: --shared <dir> (default: the repository's shared/ next to this package).

@main struct TermHarnessMain {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("term-harness: \(error)\n".utf8))
            exit(1)
        }
    }

    struct Options {
        var fake: FakeTranslator.Mode?
        var langs: [String]?
        var out: String?
        var writePacks = false
        var shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared")
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < args.count else { throw HarnessError(description: "\(name) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--fake":
                if i + 1 < args.count, let mode = FakeTranslator.Mode(rawValue: args[i + 1]) {
                    o.fake = mode
                    i += 1
                } else {
                    o.fake = .identity
                }
            case "--lang": o.langs = try value("--lang").split(separator: ",").map(String.init)
            case "--out": o.out = try value("--out")
            case "--shared": o.shared = URL(fileURLWithPath: try value("--shared"))
            case "--write-packs": o.writePacks = true
            default: throw HarnessError(description: "unknown option \(args[i])")
            }
            i += 1
        }
        if o.writePacks && o.fake != nil {
            throw HarnessError(description: "--write-packs needs real translations (drop --fake)")
        }
        return o
    }

    static func run(_ args: [String]) async throws {
        let o = try parse(args)
        let corpusDir = o.shared.appendingPathComponent("fixtures/terms")
        let langs = try o.langs ?? FileManager.default.contentsOfDirectory(atPath: corpusDir.path)
            .filter { $0.hasSuffix(".tsv") }.map { String($0.dropLast(4)) }.sorted()
        var lines: [CorpusLine] = []
        for lang in langs {
            let text = try String(contentsOf: corpusDir.appendingPathComponent("\(lang).tsv"), encoding: .utf8)
            lines += try Harness.parseCorpus(text, lang: lang)
        }

        let translator: any Translating
        let engine: String
        if let mode = o.fake {
            translator = FakeTranslator(mode)
            engine = "fake (\(mode.rawValue))"
        } else {
            let apple = AppleTranslator(languages: o.shared.appendingPathComponent("languages"))
            try await apple.checkInstalled(Set(lines.map { [$0.from, $0.to] }))
            translator = apple
            engine = "Apple Translation"
        }

        let (results, errors) = try await Harness.runCorpus(lines, shapes: Harness.shapes) { text, from, to in
            try await translator.translate(text, from: from, to: to)
        }
        let table = Harness.report(results, shapes: Harness.shapes, engine: engine)
        print(table, terminator: "")
        if !errors.isEmpty {
            log("\n\(errors.count) translation errors (counted as failures):")
            errors.prefix(20).forEach { log("  \($0)") }
        }
        if let out = o.out {
            try table.write(toFile: out, atomically: true, encoding: .utf8)
            log("table written to \(out)")
        }
        if o.writePacks {
            for (lang, best) in Harness.bestShapes(results, shapes: Harness.shapes) {
                let pack = o.shared.appendingPathComponent("languages/\(lang).json")
                guard let text = try? String(contentsOf: pack, encoding: .utf8) else {
                    log("no pack \(pack.path): skipped")
                    continue
                }
                try Harness.setPlaceholder(text, key: "applePlaceholder", shape: best.shape)
                    .write(to: pack, atomically: true, encoding: .utf8)
                log("\(lang): applePlaceholder = \(best.shape)")
            }
            log("packs changed: run `swift test` in ios/")
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }
}
