// The session state machine of ARCHITECTURE §3. Pure and immutable.

enum SessionState: Hashable, Sendable {
    case loading
    case choosing(reason: String? = nil)
    case checking(String)
    case needsDownload(String, missing: [MissingMsg], error: String? = nil)
    case downloading(String)
    case preparing(String, restarts: Int = 0)
    case running(String, restarts: Int = 0)
    case switching(from: String, to: String)
    case failed(String, reason: String)
}

enum SessionEvent: Hashable, Sendable {
    case catalogReady(saved: String?, offered: Set<String>)
    case picked(String)
    case checked([MissingMsg])
    case downloadTapped
    case downloadDone
    case downloadFailed(String)
    case started
    case startFailed(String)
    case recognizerDied
    case retry
}

/// A state plus the generation of "their" side; late results carrying an old generation are dropped by the caller.
struct Session: Hashable, Sendable {
    var state: SessionState
    var generation: Int
}

enum SessionMachine {
    /// Pure transition function. Events not listed for a state leave it unchanged.
    static func next(_ s: SessionState, _ e: SessionEvent) -> SessionState {
        switch (s, e) {
        case let (.loading, .catalogReady(saved, offered)):
            guard let saved else { return .choosing() }
            return offered.contains(saved) ? .checking(saved) : .choosing(reason: "unavailable")
        case let (.choosing, .picked(code)), let (.needsDownload, .picked(code)), let (.failed, .picked(code)):
            return .checking(code)
        case let (.checking(code), .checked(missing)):
            return afterCheck(code, missing)
        case let (.needsDownload(code, _, _), .downloadTapped):
            return .downloading(code)
        case let (.downloading(code), .downloadDone):
            // Re-check: one download may not cover every missing item.
            return .checking(code)
        case let (.downloading(code), .downloadFailed(error)):
            return .needsDownload(code, missing: [], error: error)
        case let (.preparing(code, restarts), .started):
            return .running(code, restarts: restarts)
        case let (.preparing(code, _), .startFailed(reason)):
            return .failed(code, reason: reason)
        case let (.running(code, _), .picked(y)):
            return y == code ? s : .switching(from: code, to: y)
        case let (.running(code, restarts), .recognizerDied):
            return restarts == 0 ? .preparing(code, restarts: 1) : .failed(code, reason: "recognizer stopped")
        case let (.switching(_, to), .checked(missing)):
            return afterCheck(to, missing)
        case let (.failed(code, _), .retry):
            return .checking(code)
        default:
            return s
        }
    }

    /// Applies `e`; increments the generation when a switch begins (entering a `switching` different from the old
    /// state, so a no-op event while switching keeps in-flight results valid).
    static func advance(_ s: Session, _ e: SessionEvent) -> Session {
        let n = next(s.state, e)
        let entered: Bool
        if case .switching = n, n != s.state { entered = true } else { entered = false }
        return Session(state: n, generation: entered ? s.generation + 1 : s.generation)
    }

    private static func afterCheck(_ code: String, _ missing: [MissingMsg]) -> SessionState {
        missing.isEmpty ? .preparing(code) : .needsDownload(code, missing: missing)
    }
}
