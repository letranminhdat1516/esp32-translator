import Testing
@testable import TranslatorCore

// Port of app/test/engine/session_machine_test.dart.

private func miss(_ lang: String = "ja") -> MissingMsg {
    MissingMsg(kind: .speechModel, language: lang)
}

struct TransitionCase: CustomTestStringConvertible, Sendable {
    let name: String
    let state: SessionState
    let event: SessionEvent
    let expected: SessionState
    var testDescription: String { name }
}

@Suite struct SessionMachineTests {
    static let transitions: [TransitionCase] = [
        .init(name: "loading + saved offered -> checking",
              state: .loading, event: .catalogReady(saved: "ja", offered: ["ja", "fr"]), expected: .checking("ja")),
        .init(name: "loading + no saved -> choosing",
              state: .loading, event: .catalogReady(saved: nil, offered: ["ja"]), expected: .choosing()),
        .init(name: "loading + saved not offered -> choosing(unavailable)",
              state: .loading, event: .catalogReady(saved: "de", offered: ["ja"]),
              expected: .choosing(reason: "unavailable")),
        .init(name: "choosing + pick -> checking", state: .choosing(), event: .picked("ja"), expected: .checking("ja")),
        .init(name: "checking + all present -> preparing",
              state: .checking("ja"), event: .checked([]), expected: .preparing("ja")),
        .init(name: "checking + missing -> needsDownload",
              state: .checking("ja"), event: .checked([miss()]), expected: .needsDownload("ja", missing: [miss()])),
        .init(name: "needsDownload + download -> downloading",
              state: .needsDownload("ja", missing: [miss()]), event: .downloadTapped, expected: .downloading("ja")),
        .init(name: "needsDownload + pick -> checking",
              state: .needsDownload("ja", missing: [miss()]), event: .picked("fr"), expected: .checking("fr")),
        .init(name: "downloading + done -> checking (re-check)",
              state: .downloading("ja"), event: .downloadDone, expected: .checking("ja")),
        .init(name: "downloading + error -> needsDownload with error",
              state: .downloading("ja"), event: .downloadFailed("offline"),
              expected: .needsDownload("ja", missing: [], error: "offline")),
        .init(name: "preparing + started -> running", state: .preparing("ja"), event: .started, expected: .running("ja")),
        .init(name: "preparing + started keeps restarts",
              state: .preparing("ja", restarts: 1), event: .started, expected: .running("ja", restarts: 1)),
        .init(name: "preparing + startFailed -> failed",
              state: .preparing("ja"), event: .startFailed("boom"), expected: .failed("ja", reason: "boom")),
        .init(name: "running + pick other -> switching",
              state: .running("ja"), event: .picked("fr"), expected: .switching(from: "ja", to: "fr")),
        .init(name: "running + pick same -> unchanged", state: .running("ja"), event: .picked("ja"), expected: .running("ja")),
        .init(name: "running + recognizerDied first -> preparing(restarts 1)",
              state: .running("ja"), event: .recognizerDied, expected: .preparing("ja", restarts: 1)),
        .init(name: "running + recognizerDied second -> failed",
              state: .running("ja", restarts: 1), event: .recognizerDied,
              expected: .failed("ja", reason: "recognizer stopped")),
        .init(name: "switching + ready -> preparing(to)",
              state: .switching(from: "ja", to: "fr"), event: .checked([]), expected: .preparing("fr")),
        .init(name: "switching + missing -> needsDownload(to)",
              state: .switching(from: "ja", to: "fr"), event: .checked([miss("fr")]),
              expected: .needsDownload("fr", missing: [miss("fr")])),
        .init(name: "failed + retry -> checking",
              state: .failed("ja", reason: "x"), event: .retry, expected: .checking("ja")),
        .init(name: "failed + pick -> checking",
              state: .failed("ja", reason: "x"), event: .picked("fr"), expected: .checking("fr")),
    ]

    @Test(arguments: transitions) func transition(_ c: TransitionCase) {
        #expect(SessionMachine.next(c.state, c.event) == c.expected)
    }

    static let unlisted: [TransitionCase] = [
        .init(name: "loading + started", state: .loading, event: .started, expected: .loading),
        .init(name: "running + downloadDone", state: .running("ja"), event: .downloadDone, expected: .running("ja")),
        .init(name: "downloading + picked", state: .downloading("ja"), event: .picked("fr"), expected: .downloading("ja")),
        .init(name: "choosing + retry", state: .choosing(), event: .retry, expected: .choosing()),
        .init(name: "failed + recognizerDied",
              state: .failed("ja", reason: "x"), event: .recognizerDied, expected: .failed("ja", reason: "x")),
    ]

    @Test(arguments: unlisted) func unlistedEventLeavesStateUnchanged(_ c: TransitionCase) {
        #expect(SessionMachine.next(c.state, c.event) == c.state)
    }

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

    @Test func generationIncrementsExactlyOnEnteringSwitching() {
        var s = Session(state: .running("ja"), generation: 0)
        s = SessionMachine.advance(s, .picked("fr"))
        #expect(s.state == .switching(from: "ja", to: "fr"))
        #expect(s.generation == 1)
        s = SessionMachine.advance(s, .checked([]))
        #expect(s.state == .preparing("fr"))
        #expect(s.generation == 1)
        s = SessionMachine.advance(s, .started)
        s = SessionMachine.advance(s, .picked("ko"))
        #expect(s.generation == 2)
    }

    @Test func noIncrementWhenPickEqualsCurrent() {
        let s = SessionMachine.advance(Session(state: .running("ja"), generation: 3), .picked("ja"))
        #expect(s.generation == 3)
    }

    @Test func noIncrementForANoOpEventWhileSwitching() {
        let s = SessionMachine.advance(Session(state: .switching(from: "ja", to: "fr"), generation: 4), .started)
        #expect(s.state == .switching(from: "ja", to: "fr"))
        #expect(s.generation == 4)
    }
}
