import Foundation

/// Builds the "You say" turns from the Vietnamese recognizer's events.
///
/// A turn is the finalized phrases so far plus the current volatile (partial) text. A new turn (a fresh
/// subtitle screen) starts only after the wearer has really paused: the last phrase is final and nothing
/// has arrived for `turnGap`. While a phrase is still volatile the turn never splits, even if the
/// recognizer goes quiet for a while (it often does for 2 s or more in noise before revising a phrase);
/// splitting there left the volatile text in one line and repeated it in the next.
struct TurnAssembler {
    struct Turn: Equatable {
        let id: Int
        /// Finalized phrases, loanwords fixed
        var finals: [String] = []
        /// Volatile text after the last final, loanwords fixed
        var partial = ""

        var text: String { (finals + [partial]).filter { !$0.isEmpty }.joined(separator: " ") }
    }

    struct Change: Equatable {
        /// This event opened a new turn
        var started = false
        /// A phrase that was finalized by this event (already appended to `turn.finals`)
        var final: String?
    }

    /// A pause longer than this (after a final phrase) starts a new turn
    let turnGap: TimeInterval
    /// If a volatile phrase is never finalized, give up waiting after this long
    let staleGap: TimeInterval
    /// A turn longer than this (characters or seconds) ends at its next final phrase, so hours of talk
    /// without a pause never grow one line without bound
    let maxCharacters: Int
    let maxDuration: TimeInterval

    private(set) var turn: Turn?
    private var lastEvent = Date.distantPast
    private var turnStart = Date.distantPast
    private var closeTurn = false
    private var nextID = 1

    init(turnGap: TimeInterval = 2, staleGap: TimeInterval = 10, maxCharacters: Int = 600,
         maxDuration: TimeInterval = 60) {
        self.turnGap = turnGap
        self.staleGap = staleGap
        self.maxCharacters = maxCharacters
        self.maxDuration = maxDuration
    }

    /// Forget the current turn (history cleared); the next event starts a new one
    mutating func reset() {
        turn = nil
        closeTurn = false
    }

    /// Applies one recognizer event; returns nil when nothing changed
    mutating func handle(_ event: TranscriptEvent, at now: Date) -> Change? {
        let raw: String
        switch event {
        case .partial(let t): raw = t
        case .final(let t, _): raw = t
        }
        let text = VietnameseFixup.fixLoanwords(raw.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !text.isEmpty else {
            // An empty result clears the volatile text (the phrase was dropped or is now final)
            guard var t = turn, !t.partial.isEmpty else { return nil }
            t.partial = ""
            turn = t
            return Change()
        }

        var change = Change()
        let quiet = now.timeIntervalSince(lastEvent)
        let pending = !(turn?.partial.isEmpty ?? true)
        if turn == nil || (!pending && (quiet > turnGap || closeTurn)) || quiet > staleGap {
            turn = Turn(id: nextID)
            nextID += 1
            turnStart = now
            closeTurn = false
            change.started = true
        }
        lastEvent = now

        switch event {
        case .partial:
            turn!.partial = text
        case .final:
            turn!.partial = ""
            turn!.finals.append(text)
            change.final = text
            closeTurn = turn!.text.count > maxCharacters || now.timeIntervalSince(turnStart) > maxDuration
        }
        return change
    }
}
