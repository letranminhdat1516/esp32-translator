// VI→EN with and without VietnameseFixup, using Apple Translation on this Mac (models must be installed).
//   ./vi-translate in.txt out.tsv   (one sentence per line)
// Output: source \t translator input after fix-up \t EN (raw) \t EN (with fix-up) \t ms
//   ./vi-translate --loanwords in.tsv out.tsv   (a vi-harness TSV: applies only the loanword table to
//   column 2, for rescoring WER)
import Foundation
import Translation

@main struct Main {
    static func main() async throws {
        let a = CommandLine.arguments
        if a[1] == "--loanwords" {
            let rows = try String(contentsOfFile: a[2], encoding: .utf8).split(separator: "\n").map { row in
                var cols = row.components(separatedBy: "\t")
                cols[1] = VietnameseFixup.fixLoanwords(cols[1])
                return cols.joined(separator: "\t")
            }
            try (rows.joined(separator: "\n") + "\n").write(toFile: a[3], atomically: true, encoding: .utf8)
            return
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: "vi"),
                                         target: Locale.Language(identifier: "en"))
        let lines = try String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n").map(String.init)
        var out = ""
        for line in lines {
            let fixed = VietnameseFixup.forTranslation(line)
            let raw = try await session.translate(line).targetText
            let t0 = Date()
            let en = fixed == line ? raw : try await session.translate(fixed).targetText
            out += "\(line)\t\(fixed)\t\(raw)\t\(en)\t\(Int(Date().timeIntervalSince(t0) * 1000))\n"
        }
        try out.write(toFile: a[2], atomically: true, encoding: .utf8)
    }
}
