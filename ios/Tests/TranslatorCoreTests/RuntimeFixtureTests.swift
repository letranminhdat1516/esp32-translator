import Foundation
import Testing
@testable import TranslatorCore

// Every case of the shared fixtures for the runtime pieces (adpcm, conversation_activity, subtitle_translator,
// turn_assembler), run against the Swift implementations as the TypeScript and Dart suites run them
// (android/__tests__/*.test.ts, app/test). The hand-written suites next to this file keep the Swift-only cases.

private func bytes(_ hex: String) -> Data {
    var out = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func steps(_ c: FixtureCase) -> [[String: Any]] {
    let list = c.json["steps"] as? [[String: Any]] ?? []
    precondition(!list.isEmpty, "fixture case \(c.name) has no steps")
    return list
}

// MARK: - adpcm.json

private let adpcmFixture = Fixtures.load("adpcm")

@Suite struct ADPCMFixtureTests {
    @Test func fixtureHasEverySequence() {
        #expect(Fixtures.cases(in: adpcmFixture, "sequences", fixture: "adpcm").count == 9)
    }

    @Test(arguments: Fixtures.cases(in: adpcmFixture, "sequences", fixture: "adpcm"))
    func sequence(_ c: FixtureCase) {
        var decoder = ADPCMDecoder()
        for (i, step) in steps(c).enumerated() {
            if step["reset"] as? Bool == true {
                decoder.reset()
                continue
            }
            let out = decoder.decode(bytes(step["packet"] as! String)).map(Int.init)
            #expect(out == step["expected"] as! [Int], "step \(i)")
        }
    }
}

// MARK: - conversation_activity.json

private let activityFixture = Fixtures.load("conversation_activity")

private func activityEvent(_ name: String) -> ConversationActivity.Event? {
    switch name {
    case "boardAudio": .boardAudio
    case "gateOpen": .gateOpen
    case "gateClosed": .gateClosed
    case "ttsStart": .ttsStart
    case "ttsEnd": .ttsEnd
    case "userStart": .userStart
    case "userStop": .userStop
    case "stop": .stop
    case "tick": .tick
    default: nil
    }
}

@Suite struct ConversationActivityFixtureTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func defaultsAndEventNames() {
        let defaults = activityFixture["defaults"] as! [String: Int]
        let activity = ConversationActivity()
        #expect(activity.idleTimeout * 1000 == Double(defaults["idleTimeoutMs"]!))
        #expect(activity.retryDelay * 1000 == Double(defaults["retryDelayMs"]!))
        let names = activityFixture["events"] as! [String]
        #expect(names.count == 9)
        #expect(names.allSatisfy { activityEvent($0) != nil })
        #expect(Fixtures.cases(in: activityFixture, "scenarios", fixture: "conversation_activity").count == 20)
    }

    @Test(arguments: Fixtures.cases(in: activityFixture, "scenarios", fixture: "conversation_activity"))
    func scenario(_ c: FixtureCase) throws {
        var config = activityFixture["defaults"] as! [String: Int]
        config.merge(c.json["config"] as? [String: Int] ?? [:]) { $1 }
        var activity = ConversationActivity(idleTimeout: Double(config["idleTimeoutMs"]!) / 1000,
                                            retryDelay: Double(config["retryDelayMs"]!) / 1000)
        #expect(activity.state == .idle)
        for (i, step) in steps(c).enumerated() {
            let now = t0.addingTimeInterval(Double(step["atMs"] as! Int) / 1000)
            if step["startFailed"] as? Bool == true {
                activity.startFailed(at: now)
            } else {
                let event = try #require(activityEvent(step["event"] as! String), "step \(i)")
                let got = activity.handle(event, at: now).map { $0 == .start ? "start" : "stop" }
                #expect(got == step["expect"] as? String, "step \(i)")
            }
            if let state = step["state"] as? String {
                #expect((activity.state == .active ? "active" : "idle") == state, "step \(i)")
                #expect(activity.isActive == (state == "active"), "step \(i)")
            }
        }
    }
}

// MARK: - subtitle_translator.json

private let subtitleFixture = Fixtures.load("subtitle_translator")

@MainActor
@Suite struct SubtitleTranslatorFixtureTests {
    private static let expectKeys: Set<String> = ["results", "emptyTurns", "requestCounts", "maxRequestLength",
                                                  "wordCounts"]

    @Test func fixtureHasEveryScenario() {
        #expect(Fixtures.cases(in: subtitleFixture, "scenarios", fixture: "subtitle_translator").count == 6)
    }

    @Test(arguments: Fixtures.cases(in: subtitleFixture, "scenarios", fixture: "subtitle_translator"))
    func scenario(_ c: FixtureCase) async throws {
        let j = c.json
        let spec = j["translator"] as! [String: Any]
        let fake = FakeTranslator(delay: .milliseconds(spec["delayMs"] as! Int))
        for text in spec["failing"] as? [String] ?? [] { await fake.fail(on: text) }
        let results = Results()
        let st = SubtitleTranslator(translate: { try await fake.translate($0) }) { results.byTurn[$0] = $1 }
        // Consecutive non-wait steps run as one synchronous burst (no suspension between them on the main actor)
        for step in steps(c) {
            switch step["op"] as! String {
            case "partial": st.setPartial(step["text"] as! String, turn: step["turn"] as! Int)
            case "final": st.addFinal(step["text"] as! String, turn: step["turn"] as! Int)
            case "reset": st.reset()
            case "wait":
                // The fixture's wait in real time, then until the queue is drained, so a loaded machine is not flaky
                try await Task.sleep(for: .milliseconds(step["ms"] as! Int))
                await st.idle()
            case let op: Issue.record("unknown op \(op)")
            }
        }

        let want = j["expect"] as! [String: Any]
        #expect(!want.isEmpty && Set(want.keys).isSubset(of: Self.expectKeys), "expect keys \(want.keys.sorted())")
        for (turn, text) in want["results"] as? [String: String] ?? [:] {
            #expect(results.byTurn[Int(turn)!] == text, "turn \(turn)")
        }
        for turn in want["emptyTurns"] as? [Int] ?? [] {
            #expect((results.byTurn[turn] ?? "") == "", "turn \(turn)")
        }
        let requests = await fake.requests
        for r in want["requestCounts"] as? [[String: Any]] ?? [] {
            let text = r["text"] as! String
            let n = requests.filter { $0 == text }.count
            if let exactly = r["exactly"] as? Int { #expect(n == exactly, "requests for \"\(text)\"") }
            if let max = r["max"] as? Int { #expect(n <= max, "requests for \"\(text)\"") }
        }
        if let maxLength = want["maxRequestLength"] as? Int {
            // Dart String.length (UTF-16 code units), as in the reference test
            #expect(requests.map(\.utf16.count).max() ?? 0 <= maxLength)
        }
        for (turn, count) in want["wordCounts"] as? [String: Int] ?? [:] {
            let words = (results.byTurn[Int(turn)!] ?? "").split(separator: " ")
            #expect(words.count == count, "turn \(turn)")
        }
    }
}

// MARK: - turn_assembler.json

private let turnFixture = Fixtures.load("turn_assembler")

/// The assembler for a case's config over the defaults. Swift always fixes Vietnamese loanwords
/// (`VietnameseFixup`), which is what `fixLoanwords: "vi"` asks for; only "vi" is used by the fixture.
private func assembler(_ c: FixtureCase) -> TurnAssembler {
    var config = turnFixture["defaults"] as! [String: Any]
    config.merge(c.json["config"] as? [String: Any] ?? [:]) { $1 }
    if let pack = config["fixLoanwords"] as? String { precondition(pack == "vi", "unsupported fixLoanwords \(pack)") }
    return TurnAssembler(turnGap: Double(config["turnGapMs"] as! Int) / 1000,
                         staleGap: Double(config["staleGapMs"] as! Int) / 1000,
                         maxCharacters: config["maxCharacters"] as! Int,
                         maxDuration: Double(config["maxDurationMs"] as! Int) / 1000)
}

private func transcriptEvent(_ kind: String, _ text: String) -> TranscriptEvent {
    kind == "final" ? .final(text, confidence: nil) : .partial(text)
}

@Suite struct TurnAssemblerFixtureTests {
    let t0 = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01, as the TypeScript test

    @Test func fixtureHasEveryScenarioAndReplay() {
        #expect(Fixtures.cases(in: turnFixture, "scenarios", fixture: "turn_assembler").count == 6)
        #expect(Fixtures.cases(in: turnFixture, "replays", fixture: "turn_assembler").count == 2)
    }

    @Test(arguments: Fixtures.cases(in: turnFixture, "scenarios", fixture: "turn_assembler"))
    func scenario(_ c: FixtureCase) {
        let j = c.json
        var a = assembler(c)
        var ids: Set<Int> = []
        for (i, step) in steps(c).enumerated() {
            let kind = step["kind"] as! String
            if kind == "reset" {
                a.reset()
            } else {
                #expect(kind == "partial" || kind == "final", "step \(i): unknown kind \(kind)")
                let change = a.handle(transcriptEvent(kind, step["text"] as! String),
                                      at: t0.addingTimeInterval(Double(step["atMs"] as! Int) / 1000))
                if step.keys.contains("change") {
                    if let want = step["change"] as? [String: Any] {
                        #expect(change?.started == want["started"] as? Bool, "step \(i)")
                        #expect(change?.final == want["finalText"] as? String, "step \(i)")
                        #expect(change != nil, "step \(i)")
                    } else {
                        #expect(change == nil, "step \(i)")
                    }
                }
            }
            if let text = step["turnText"] as? String { #expect(a.turn?.text == text, "step \(i)") }
            if step["turnIsNull"] as? Bool == true { #expect(a.turn == nil, "step \(i)") }
            if let turn = a.turn { ids.insert(turn.id) }
            if let maxLength = j["maxTurnTextLength"] as? Int {
                // Dart String.length (UTF-16 code units), as in the reference test
                #expect((a.turn?.text.utf16.count ?? 0) <= maxLength, "step \(i)")
            }
        }
        if let minTurns = j["minDistinctTurns"] as? Int { #expect(ids.count >= minTurns) }
    }

    @Test(arguments: Fixtures.cases(in: turnFixture, "replays", fixture: "turn_assembler"))
    func replay(_ c: FixtureCase) throws {
        let j = c.json
        var a = assembler(c)
        let url = Fixtures.sharedDirectory.appendingPathComponent("fixtures/\(j["recording"] as! String)")
        let records = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(!records.isEmpty)
        var lines: [Int: String] = [:]
        var order: [Int] = []
        for line in records {
            let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let now = t0.addingTimeInterval(d["t"] as! Double)
            guard a.handle(transcriptEvent(d["kind"] as! String, d["text"] as! String), at: now) != nil,
                  let turn = a.turn else { continue }
            if lines[turn.id] == nil { order.append(turn.id) }
            lines[turn.id] = turn.text
        }
        let expected = j["expectLines"] as! [String]
        #expect(!expected.isEmpty)
        #expect(order.map { lines[$0]! } == expected)
    }
}
