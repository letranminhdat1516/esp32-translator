import Foundation

/// Live VI→EN subtitles for the "You say" turns.
///
/// Each finalized phrase is translated once, in order, and kept; only the current volatile phrase is
/// re-translated as it changes (latest wins, stale requests are dropped). A turn's English is the
/// finals' translations followed by the volatile one. Re-translating the whole growing turn on every
/// partial (as before) made each request longer the longer you spoke, so the work grew with the square
/// of the turn length and the translator got a single unpunctuated run-on sentence; here every request is
/// one phrase between pauses.
@MainActor
final class SubtitleTranslator {
    private struct TurnState {
        /// English per final phrase; nil until translated (then `placeholders` is shown)
        var finals: [String?] = []
        var placeholders: [String] = []
        var partialSource = ""
        var partial = ""
        var english: String {
            (zip(finals, placeholders).map { $0 ?? $1 } + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private let translate: (String) async throws -> String
    private let onResult: (_ turn: Int, _ english: String) -> Void
    /// The refine step for a final phrase: (turn, source, draft) → a better translation, nil to keep the draft
    private let refine: ((_ turn: Int, _ source: String, _ draft: String) async -> String?)?
    private var turns: [Int: TurnState] = [:]
    private var finalJobs: [(turn: Int, index: Int, text: String)] = []
    private var partialJob: (turn: Int, text: String)?
    /// The task working through the queue, nil when idle
    private var worker: Task<Void, Never>?
    /// Refine requests in flight, apart from the queue so a slow model never holds the next phrase
    private var refines: [UUID: Task<Void, Never>] = [:]

    /// `translate` is the VI→EN translator (`Translator.translate`; a stub in tests). `refine`, when given, runs
    /// after each final phrase's translation is shown; its result replaces that phrase if it still shows the draft.
    init(translate: @escaping (String) async throws -> String,
         refine: ((_ turn: Int, _ source: String, _ draft: String) async -> String?)? = nil,
         onResult: @escaping (_ turn: Int, _ english: String) -> Void) {
        self.translate = translate
        self.refine = refine
        self.onResult = onResult
    }

    /// A finalized phrase of `turn` (text already prepared for the translator)
    func addFinal(_ text: String, turn: Int) {
        var state = turns[turn] ?? TurnState()
        state.finals.append(nil)
        // Until its translation arrives, the phrase keeps showing the English of its volatile version
        state.placeholders.append(state.partial)
        state.partial = ""
        state.partialSource = ""
        if partialJob?.turn == turn { partialJob = nil }
        if text.isEmpty {
            // Nothing to translate (e.g. the phrase was only "em ơi")
            state.finals[state.finals.count - 1] = ""
            turns[turn] = state
            onResult(turn, state.english)
            return
        }
        turns[turn] = state
        finalJobs.append((turn, state.finals.count - 1, text))
        // Keep only the last few turns (late results for older lines are dropped)
        turns = turns.filter { $0.key > turn - 3 }
        run()
    }

    /// Drops every turn and pending request (history cleared)
    func reset() {
        turns.removeAll()
        refines.values.forEach { $0.cancel() }
        finalJobs.removeAll()
        partialJob = nil
    }

    /// The current volatile phrase of `turn` (empty: none)
    func setPartial(_ text: String, turn: Int) {
        var state = turns[turn] ?? TurnState()
        guard text != state.partialSource else { return }
        state.partialSource = text
        if text.isEmpty {
            state.partial = ""
            partialJob = nil
            turns[turn] = state
            onResult(turn, state.english)
            return
        }
        turns[turn] = state
        partialJob = (turn, text)
        run()
    }

    /// Returns once every queued request has been handled (tests await this instead of sleeping)
    func idle() async {
        while worker != nil || !refines.isEmpty {
            if let worker { await worker.value }
            if let next = refines.values.first { await next.value }
        }
    }

    private func run() {
        guard worker == nil else { return }
        worker = Task {
            while true {
                if !finalJobs.isEmpty {
                    let job = finalJobs.removeFirst()
                    let english = await translated(job.text)
                    guard var state = turns[job.turn], job.index < state.finals.count else { continue }
                    state.finals[job.index] = english ?? state.placeholders[job.index]
                    turns[job.turn] = state
                    onResult(job.turn, state.english)
                    if let english, !english.isEmpty { startRefine(job, draft: english) }
                } else if let job = partialJob {
                    partialJob = nil
                    let english = await translated(job.text)
                    // Drop it if the phrase changed or was finalized meanwhile
                    guard var state = turns[job.turn], state.partialSource == job.text, let english else { continue }
                    state.partial = english
                    turns[job.turn] = state
                    onResult(job.turn, state.english)
                } else {
                    break
                }
            }
            worker = nil
        }
    }

    /// Refines one final phrase off the queue; the result lands only if the phrase still shows `draft` (not after a
    /// reset or once the turn was dropped).
    private func startRefine(_ job: (turn: Int, index: Int, text: String), draft: String) {
        guard let refine else { return }
        let id = UUID()
        refines[id] = Task {
            defer { refines[id] = nil }
            guard let better = await refine(job.turn, job.text, draft), !Task.isCancelled,
                  var state = turns[job.turn], job.index < state.finals.count, state.finals[job.index] == draft
            else { return }
            state.finals[job.index] = better
            turns[job.turn] = state
            onResult(job.turn, state.english)
        }
    }

    private func translated(_ text: String) async -> String? {
        do {
            return try await translate(text)
        } catch {
            Diag.log("translate VI→EN FAILED (\(text.count) chars): \(error)")
            return nil
        }
    }
}
