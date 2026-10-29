import Testing
@testable import TranslatorCore

// Port of app/test/engine/session_machine_test.dart, driven by shared/fixtures/session_machine.json (hand-picked
// transitions, the full 9 x 10 matrix, generations), plus Swift-only cases.

private let fixture = Fixtures.load("session_machine")

private func missing(_ v: Any?) -> [MissingMsg] {
    (v as! [[String: Any]]).map { m in
        MissingMsg(kind: MissingKind(rawValue: m["kind"] as! String)!, language: m["language"] as! String,
                   from: m["from"] as? String, to: m["to"] as? String)
    }
}

/// A fixture `State` object.
private func state(_ j: [String: Any]) -> SessionState {
    switch j["type"] as! String {
    case "loading": return .loading
    case "choosing": return .choosing(reason: j["reason"] as? String)
    case "checking": return .checking(j["code"] as! String)
    case "needsDownload":
        return .needsDownload(j["code"] as! String, missing: missing(j["missing"]), error: j["error"] as? String)
    case "downloading": return .downloading(j["code"] as! String)
    case "preparing": return .preparing(j["code"] as! String, restarts: j["restarts"] as! Int)
    case "running": return .running(j["code"] as! String, restarts: j["restarts"] as! Int)
    case "switching": return .switching(from: j["from"] as! String, to: j["to"] as! String)
    case "failed": return .failed(j["code"] as! String, reason: j["reason"] as! String)
    case let t: fatalError("unknown state type \(t)")
    }
}

/// A fixture `Event` object.
private func event(_ j: [String: Any]) -> SessionEvent {
    switch j["type"] as! String {
    case "catalogReady": return .catalogReady(saved: j["saved"] as? String, offered: Set(j["offered"] as! [String]))
    case "picked": return .picked(j["code"] as! String)
    case "checked": return .checked(missing(j["missing"]))
    case "downloadTapped": return .downloadTapped
    case "downloadDone": return .downloadDone
    case "downloadFailed": return .downloadFailed(j["error"] as! String)
    case "started": return .started
    case "startFailed": return .startFailed(j["reason"] as! String)
    case "recognizerDied": return .recognizerDied
    case "retry": return .retry
    case let t: fatalError("unknown event type \(t)")
    }
}

@Suite struct SessionMachineFixtureTests {
    @Test func missingKinds() {
        #expect(MissingKind.allCases.map(\.rawValue) == fixture["missingKinds"] as! [String])
    }

    @Test(arguments: Fixtures.cases(in: fixture, "transitions", fixture: "session_machine"))
    func transition(_ c: FixtureCase) {
        let j = c.json
        let s = state(j["state"] as! [String: Any])
        let e = event(j["event"] as! [String: Any])
        #expect(SessionMachine.next(s, e) == state(j["expected"] as! [String: Any]))
    }

    @Test(arguments: Fixtures.cases(in: fixture, "matrix", fixture: "session_machine"))
    func matrixCell(_ c: FixtureCase) {
        let j = c.json
        let s = state(j["state"] as! [String: Any])
        let e = event(j["event"] as! [String: Any])
        #expect(SessionMachine.next(s, e) == state(j["expected"] as! [String: Any]))
    }

    @Test func matrixHasEveryStateEventPair() {
        let cells = (fixture["matrix"] as! [[String: Any]]).map { cell in
            "\((cell["state"] as! [String: Any])["type"]!)+\((cell["event"] as! [String: Any])["type"]!)"
        }
        #expect(cells.count == 90)
        #expect(Set(cells).count == 90)
    }

    @Test(arguments: Fixtures.cases(in: fixture, "generations", fixture: "session_machine"))
    func generations(_ c: FixtureCase) {
        let j = c.json
        let start = j["start"] as! [String: Any]
        var s = Session(state: state(start["state"] as! [String: Any]), generation: start["generation"] as! Int)
        for (i, step) in (j["steps"] as! [[String: Any]]).enumerated() {
            s = SessionMachine.advance(s, event(step["event"] as! [String: Any]))
            #expect(s.state == state(step["state"] as! [String: Any]), "step \(i)")
            #expect(s.generation == step["generation"] as! Int, "step \(i)")
        }
    }
}

@Suite struct SessionMachineTests {
    private func miss(_ lang: String = "ja") -> MissingMsg { MissingMsg(kind: .speechModel, language: lang) }

    @Test func needsDownloadComparesMissingByFields() {
        let a = SessionState.needsDownload("ja", missing: [miss()])
        #expect(a == .needsDownload("ja", missing: [miss()]))
        #expect(a != .needsDownload("ja", missing: [miss("fr")]))
        #expect(a.hashValue == SessionState.needsDownload("ja", missing: [miss()]).hashValue)
    }

    @Test func differentStateTypesAreNotEqual() {
        #expect(SessionState.preparing("ja") != .running("ja"))
        #expect(SessionState.running("ja") != .running("ja", restarts: 1))
    }

    @Test func noIncrementForANoOpEventWhileSwitching() {
        let s = SessionMachine.advance(Session(state: .switching(from: "ja", to: "fr"), generation: 4), .started)
        #expect(s.state == .switching(from: "ja", to: "fr"))
        #expect(s.generation == 4)
    }
}
