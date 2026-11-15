import Foundation
import Synchronization

// The refine step (docs/translation-refine.md): the machine translation is shown and spoken at once; then an
// on-device language model gets the source, the draft, the last lines of the conversation and the glossary terms,
// and its fix replaces the line when it passes `RefineCheck`. Any failure (unsupported pair, slow, refused,
// implausible) keeps the draft. Prompt building, checks and ordering live here; the model is `RefineModel`
// (FoundationModels in the app, a fake in tests).

/// A line of the conversation given to the model as context.
struct RefineTurn: Hashable, Sendable {
    /// Spoken by the wearer (Vietnamese) rather than the other person
    var mine: Bool
    var source: String
    var target: String
}

/// A glossary or pack term found in the source and what it must become in the translation.
struct RefineTerm: Hashable, Sendable {
    var source: String
    var target: String
}

/// One phrase to refine: `from`/`to` are language codes (`LanguageCatalog` codes, e.g. "ja", "zh-Hans").
struct RefineRequest: Hashable, Sendable {
    var source: String
    var draft: String
    var from: String
    var to: String
    var context: [RefineTurn] = []
    var terms: [RefineTerm] = []
}

/// The language model behind the refine step.
protocol RefineModel: Sendable {
    /// The model is usable now and handles language `code`.
    func supports(_ code: String) -> Bool
    /// Loads the model ahead of the first request (no-op when it cannot).
    func prewarm()
    /// A plain-text reply to `prompt` under `instructions`; throws on refusal or failure.
    func respond(instructions: String, prompt: String) async throws -> String
}

enum RefinePrompt {
    /// Context lines, the source and the draft are cut to these lengths (the model has a 4096-token window)
    static let maxContextChars = 200
    static let maxPhraseChars = 600

    static let instructions = """
        You fix machine translations in a live spoken conversation between a Vietnamese speaker (Me) and a \
        foreign speaker (Them). You get a phrase as recognized from speech, a draft machine translation, recent \
        lines of the conversation and required terms. Reply with the corrected translation only: one line, no \
        quotes, no notes. Keep the meaning of the source exactly; do not add, explain, answer or summarize. Use \
        the conversation to choose pronouns, names and the level of politeness. Write every required term \
        exactly as given and keep names as they are. If the draft is already right, reply with the draft unchanged.
        """

    static func prompt(_ r: RefineRequest) -> String {
        let home = LanguageCatalog.homeCode
        let other = r.from == home ? r.to : r.from
        var parts: [String] = []
        if !r.context.isEmpty {
            let lines = r.context.map { turn in
                let who = turn.mine ? "Me (\(name(home)))" : "Them (\(name(other)))"
                return "\(who): \(cut(turn.source, maxContextChars)) = \(cut(turn.target, maxContextChars))"
            }
            parts.append("Recent conversation, oldest first:\n" + lines.joined(separator: "\n"))
        }
        if !r.terms.isEmpty {
            parts.append("Required terms (source → translation):\n"
                         + r.terms.map { "\($0.source) → \($0.target)" }.joined(separator: "\n"))
        }
        parts.append("""
            Translate from \(name(r.from)) to \(name(r.to)).
            Source: \(cut(r.source, maxPhraseChars))
            Draft translation: \(cut(r.draft, maxPhraseChars))
            Corrected translation:
            """)
        return parts.joined(separator: "\n\n")
    }

    /// The last `limit` translated lines before line `id` (by time), unclear lines left out.
    static func context(_ lines: [UILine], before id: String, limit: Int = 4) -> [RefineTurn] {
        let end = lines.first { $0.id == id }?.at ?? .distantFuture
        return lines
            .filter { $0.id != id && $0.at < end && !$0.unclear && !$0.target.isEmpty && !$0.source.isEmpty }
            .sorted { $0.at < $1.at }
            .suffix(limit)
            .map { RefineTurn(mine: $0.mine, source: $0.source, target: $0.target) }
    }

    /// English language name for the prompt ("ja" → "Japanese", "zh-Hans" → "Chinese (Simplified)").
    static func name(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    private static func cut(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}

/// Whether a model reply is a plausible translation of the request: cleaned of labels and quotes, or nil.
enum RefineCheck {
    private static let labels = ["corrected translation:", "translation:", "corrected:", "draft translation:"]
    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")]

    static func accept(_ raw: String, for r: RefineRequest) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in labels where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        // Far longer than the draft: an explanation or an answer, not a translation
        guard text.count <= max(r.draft.count * 2, r.draft.count + 24) else { return nil }
        // A copy of the source
        if r.from != r.to, fold(text) == fold(r.source) { return nil }
        // A required term the draft had must survive
        for term in r.terms where contains(r.draft, term.target) && !contains(text, term.target) { return nil }
        return inTargetLanguage(text, r) ? text : nil
    }

    /// Script checks on the reply with the required terms taken out (a fixed term may keep its own script).
    private static func inTargetLanguage(_ text: String, _ r: RefineRequest) -> Bool {
        var rest = text
        for term in r.terms.sorted(by: { $0.target.count > $1.target.count }) {
            rest = rest.replacingOccurrences(of: term.target, with: " ", options: .caseInsensitive)
            rest = rest.replacingOccurrences(of: term.source, with: " ", options: .caseInsensitive)
        }
        let scalars = rest.unicodeScalars
        let han = scalars.contains { isHan($0) }, kana = scalars.contains { isKana($0) }
        let hangul = scalars.contains { isHangul($0) }, thai = scalars.contains { isThai($0) }
        let words = rest.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        switch r.to {
        case "ja": return han || kana
        case "ko": return hangul
        case "th": return thai
        case let code where code.hasPrefix("zh"): return han && !kana && !hangul
        case LanguageCatalog.homeCode:
            guard !(han || kana || hangul || thai) else { return false }
            // Left in English (or another unaccented language) where the draft was Vietnamese
            if words.count >= 3, hasDiacritic(r.draft), !hasDiacritic(rest) { return false }
            return true
        default:
            guard !(han || kana || hangul || thai) else { return false }
            // Vietnamese came back into a Latin-script language
            let vietnamese = words.filter { looksVietnamese(String($0)) }.count
            return !(vietnamese >= 2 && Double(vietnamese) >= Double(words.count) * 0.25)
        }
    }

    private static func fold(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
    }

    private static func contains(_ s: String, _ part: String) -> Bool {
        !part.isEmpty && s.range(of: part, options: [.caseInsensitive]) != nil
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value { case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true; default: false }
    }
    private static func isKana(_ s: Unicode.Scalar) -> Bool { (0x3040...0x30FF).contains(s.value) }
    private static func isHangul(_ s: Unicode.Scalar) -> Bool {
        switch s.value { case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3: true; default: false }
    }
    private static func isThai(_ s: Unicode.Scalar) -> Bool { (0x0E00...0x0E7F).contains(s.value) }

    /// Any letter with a combining mark, or đ.
    private static func hasDiacritic(_ s: String) -> Bool {
        s.decomposedStringWithCanonicalMapping.unicodeScalars.contains { (0x0300...0x036F).contains($0.value) }
            || s.contains("đ") || s.contains("Đ")
    }

    /// Marks used by Vietnamese and hardly by French, German or Spanish: hook above, dot below, horn, breve; đ.
    private static func looksVietnamese(_ word: String) -> Bool {
        word.contains("đ") || word.contains("Đ") || word.decomposedStringWithCanonicalMapping.unicodeScalars.contains {
            [0x0309, 0x0323, 0x031B, 0x0306].contains($0.value)
        }
    }
}

/// Runs a `RefineRequest` through the model with a time limit. Nil means "keep the draft".
final class TranslationRefiner: Sendable {
    let model: any RefineModel
    let timeout: Duration

    init(model: any RefineModel, timeout: Duration = .seconds(2)) {
        self.model = model
        self.timeout = timeout
    }

    func supports(from: String, to: String) -> Bool { model.supports(from) && model.supports(to) }

    func prewarm() { model.prewarm() }

    /// The checked fix when it differs from the draft; nil when unsupported, slower than `timeout`, refused,
    /// implausible or unchanged. Returns at `timeout` at the latest, even if the model keeps working.
    func refine(_ r: RefineRequest) async -> String? {
        guard !r.draft.isEmpty, supports(from: r.from, to: r.to) else { return nil }
        let model = self.model, timeout = self.timeout, prompt = RefinePrompt.prompt(r)
        let started = ContinuousClock.now
        let raw: String? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let work = Task {
                do {
                    once.resume(try await model.respond(instructions: RefinePrompt.instructions, prompt: prompt))
                } catch {
                    Diag.log("refine \(r.from)→\(r.to): \(error)")
                    once.resume(nil)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.resume(nil) {
                    Diag.log("refine \(r.from)→\(r.to): timed out after \(timeout)")
                    work.cancel()
                }
            }
        }
        guard let raw else { return nil }
        guard let text = RefineCheck.accept(raw, for: r) else {
            Diag.log("refine \(r.from)→\(r.to): rejected (\(raw.count) chars)")
            return nil
        }
        guard text != r.draft else { return nil }
        Diag.log("refine \(r.from)→\(r.to): changed in \(ContinuousClock.now - started)")
        return text
    }

    /// Resumes a continuation exactly once; `resume` tells whether this call did it.
    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<String?, Never>?>

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = Mutex(continuation) }

        @discardableResult
        func resume(_ value: String?) -> Bool {
            guard let c = continuation.withLock({ c in defer { c = nil }; return c }) else { return false }
            c.resume(returning: value)
            return true
        }
    }
}

/// Where a refined translation may land.
enum RefineApply {
    /// The index of line `id` if it still shows `draft` and the user did not correct it; nil otherwise (the line
    /// moved on, was corrected or is gone: the refine is stale).
    static func index(of id: String, draft: String, in lines: [UILine], edited: Set<String>) -> Int? {
        guard !edited.contains(id), let i = lines.lastIndex(where: { $0.id == id }), lines[i].target == draft
        else { return nil }
        return i
    }
}
