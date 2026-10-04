import Foundation
import Testing
@testable import ClaudeBoardCore

final class FakeStream: VoiceStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _fed = 0
    private var _cancelled = false
    private let text: String
    private let finishDelay: Duration

    init(text: String, finishDelay: Duration) { self.text = text; self.finishDelay = finishDelay }

    func feed(_ samples: [Int16]) { lock.withLock { _fed += samples.count } }
    func finish() async -> String { try? await Task.sleep(for: finishDelay); return text }
    func cancel() async { lock.withLock { _cancelled = true } }
    var fed: Int { lock.withLock { _fed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
}

final class FakeEngine: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [String]
    private var _streams: [FakeStream] = []
    private var onPartial: (@Sendable (String) -> Void)?
    var unavailable: String? { get { lock.withLock { _unavailable } } set { lock.withLock { _unavailable = newValue } } }
    private var _unavailable: String?
    let beginDelay: Duration
    let finishDelay: Duration

    init(finals: [String], beginDelay: Duration = .zero, finishDelay: Duration = .zero) {
        self.finals = finals
        self.beginDelay = beginDelay
        self.finishDelay = finishDelay
    }

    func prepare() async -> String? { unavailable }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        try? await Task.sleep(for: beginDelay)
        return lock.withLock {
            let s = FakeStream(text: finals.isEmpty ? "" : finals.removeFirst(), finishDelay: finishDelay)
            _streams.append(s)
            self.onPartial = onPartial
            return s
        }
    }

    var streams: [FakeStream] { lock.withLock { _streams } }
    func say(_ text: String) { lock.withLock { onPartial }?(text) }
}

final class FakeTyper: PaneTyping, @unchecked Sendable {
    private let lock = NSLock()
    private var _typed: [(String, PaneTarget)] = []
    var verifyResult: String?
    var typeResult: TypeResult = .typed

    func verify(_ target: PaneTarget) async -> String? { lock.withLock { verifyResult } }
    func type(_ text: String, into target: PaneTarget) async -> TypeResult {
        lock.withLock { _typed.append((text, target)); return typeResult }
    }
    var typed: [String] { lock.withLock { _typed.map(\.0) } }
    var panes: [PaneTarget] { lock.withLock { _typed.map(\.1) } }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double = 1_000
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
}

final class Targets: @unchecked Sendable {
    private let lock = NSLock()
    private var byHandle: [UInt32: VoiceTarget]
    init(_ byHandle: [UInt32: VoiceTarget]) { self.byHandle = byHandle }
    func get(_ h: UInt32) -> VoiceTarget? { lock.withLock { byHandle[h] } }
}

extension Sent {
    func updates(_ voice: UInt32) -> [VoiceUpdate] {
        messages.compactMap { if case .voice(let id, let u) = $0, id == voice { u } else { nil } }
    }
}

private let pane = PaneTarget(pane: "%3", socket: "/tmp/s", ancestors: [500, 400])
private func session(_ state: SessionState = .idle, pane p: PaneTarget? = pane) -> VoiceTarget {
    VoiceTarget(sessionId: "s1", project: "esp32", state: state, pane: p)
}

private func packet(_ seq: UInt8) -> Data { Data([seq, 0, 0, 0, 0, 0x07]) }   // 2 samples

private struct Rig {
    let hub: VoiceHub
    let sent: Sent
    let requests: RequestQueue
    let engine: FakeEngine?
    let typer: FakeTyper
    let clock: FakeClock
}

private func rig(engine: FakeEngine? = FakeEngine(finals: ["  chạy\ncác bài kiểm tra "]),
                 target: VoiceTarget? = session(), maxCapture: Duration = .seconds(120)) -> Rig {
    let sent = Sent()
    let requests = RequestQueue(send: { await sent.add($0) })
    let typer = FakeTyper()
    let clock = FakeClock()
    let targets = Targets(target.map { [7: $0] } ?? [:])
    let hub = VoiceHub(engine: engine, typer: typer, requests: requests, target: { targets.get($0) },
                       clock: { clock.now }, maxCapture: maxCapture)
    return Rig(hub: hub, sent: sent, requests: requests, engine: engine, typer: typer, clock: clock)
}

private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

@Test func commandIsTypedOnlyAfterSend() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.audio(packet(0))
    await r.hub.audio(packet(1))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.audio(packet(2))                                  // after stop: ignored
    await settle()
    #expect(await r.sent.updates(9) == [.final("chạy các bài kiểm tra")])
    #expect(r.engine!.streams[0].fed == 4)
    #expect(r.typer.typed.isEmpty)                                // nothing before an explicit Send
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(r.typer.typed == ["chạy các bài kiểm tra"] && r.typer.panes == [pane])
    #expect(await r.sent.updates(9).last == .done("Sent to esp32"))
    await r.hub.input(.voiceSend(voice: 9))                       // a second Send: the capture is over
    #expect(r.typer.typed.count == 1)
}

@Test func stopBeforeTheEngineIsReadyStillFinishes() async {
    let r = rig(engine: FakeEngine(finals: ["xin chào"], beginDelay: .milliseconds(100)))
    let starting = Task { await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7)) }
    try? await Task.sleep(for: .milliseconds(30))
    await r.hub.audio(packet(0))                                  // buffered until the engine is ready
    await r.hub.input(.voiceStop(voice: 9))
    await starting.value
    await settle()
    #expect(r.engine!.streams[0].fed == 2)
    #expect(await r.sent.updates(9) == [.final("xin chào")])
}

@Test func emptyTranscriptIsNeverTyped() async {
    let r = rig(engine: FakeEngine(finals: ["  ! /  "]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final(""), .error("Nothing to send")])
    #expect(r.typer.typed.isEmpty)
}

@Test func needsYouIsNeverTypedInto() async {
    let r = rig(target: session(.needsYou))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9).last == .error("Claude is waiting for an answer in the terminal — nothing sent"))
    #expect(r.typer.typed.isEmpty)
}

@Test func startErrorsComeBeforeAnyRecording() async {
    let noPane = rig(target: session(pane: nil))
    await noPane.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let ended = rig(target: session(.ended))
    await ended.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let unknown = rig(target: nil)
    await unknown.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let unverified = rig()
    unverified.typer.verifyResult = "The tmux pane is gone — nothing sent"
    await unverified.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await settle()
    #expect(await noPane.sent.updates(9) == [.error("Open with cb for voice")])
    #expect(await ended.sent.updates(9) == [.error("This session has ended")])
    #expect(await unknown.sent.updates(9) == [.error("Session not found")])
    #expect(await unverified.sent.updates(9) == [.error("The tmux pane is gone — nothing sent")])
    for r in [noPane, ended, unknown, unverified] { #expect(r.engine!.streams.isEmpty) }
}

@Test func typingFailureIsShown() async {
    let r = rig()
    r.typer.typeResult = .failed("The pane runs another program now — nothing sent")
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9).last == .error("The pane runs another program now — nothing sent"))
}

@Test func engineMissingOrUnavailable() async {
    let none = rig(engine: nil)
    await none.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let engine = FakeEngine(finals: ["a", "b"])
    engine.unavailable = "Allow Speech Recognition for claude-board in System Settings"
    let denied = rig(engine: engine)
    await denied.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    engine.unavailable = nil                                      // granted later: not cached as a failure
    await denied.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))
    await denied.hub.input(.voiceStop(voice: 10))
    await settle()
    #expect(await none.sent.updates(9) == [.error("Voice needs macOS 26 on the Mac")])
    #expect(await denied.sent.updates(9) == [.error("Allow Speech Recognition for claude-board in System Settings")])
    #expect(await denied.sent.updates(10) == [.final("a")])
}

@Test func staleVoiceIdsAreIgnored() async {
    let r = rig(engine: FakeEngine(finals: ["một", "hai"]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))   // Say again (replaces 9)
    await r.hub.input(.voiceSend(voice: 9))                                    // stale: ignored
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceCancel(voice: 9))
    #expect(r.typer.typed.isEmpty)
    await r.hub.input(.voiceStop(voice: 10))
    await r.hub.input(.voiceSend(voice: 10))
    await settle()
    #expect(r.typer.typed == ["hai"])
    #expect(await r.sent.updates(9) == [.final("một")])
}

@Test func aNewStartCancelsTheRunningCapture() async {
    let r = rig(engine: FakeEngine(finals: ["một", "hai"]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))
    #expect(r.engine!.streams[0].cancelled)
}

@Test func sendBeforeTheFinalIsIgnored() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.typer.typed.isEmpty)
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.typer.typed == ["chạy các bài kiểm tra"])
}

@Test func cancelWhileFinishingDropsTheText() async {
    let r = rig(engine: FakeEngine(finals: ["xin chào"], finishDelay: .milliseconds(150)))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let stopping = Task { await r.hub.input(.voiceStop(voice: 9)) }
    try? await Task.sleep(for: .milliseconds(40))
    await r.hub.input(.voiceCancel(voice: 9))
    await stopping.value
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(r.engine!.streams[0].cancelled)
    #expect(await r.sent.updates(9).isEmpty)
    #expect(r.typer.typed.isEmpty)
}

@Test func disconnectDropsTheCapture() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.boardDisconnected()
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.engine!.streams[0].cancelled && r.typer.typed.isEmpty)
}

@Test func partialsAreThrottledAndStopAtStop() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    r.engine!.say("chạy");             await settle()
    r.clock.advance(0.1)
    r.engine!.say("chạy các");         await settle()               // within 250 ms: dropped
    r.clock.advance(0.2)
    r.engine!.say("chạy các bài");     await settle()
    r.clock.advance(0.3)
    r.engine!.say("chạy các bài");     await settle()               // unchanged: dropped
    await r.hub.input(.voiceStop(voice: 9))
    r.clock.advance(0.3)
    r.engine!.say("chạy các bài kiểm"); await settle()              // after stop: dropped
    #expect(await r.sent.updates(9) == [.partial("chạy"), .partial("chạy các bài"), .final("chạy các bài kiểm tra")])
}

@Test func captureThatNeverStopsTimesOut() async {
    let r = rig(maxCapture: .milliseconds(80))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(await r.sent.updates(9) == [.error("Timed out — say it again")])
    #expect(r.engine!.streams[0].cancelled)
}

private let colour = AskQuestion(question: "Which colour?", header: "Colour",
                                 options: ["Red", "Green"].map { AskOption(label: $0, description: "") }, multiSelect: false)
private let fruit = AskQuestion(question: "Which fruits?", header: "Fruits",
                                options: ["Apple", "Banana"].map { AskOption(label: $0, description: "") }, multiSelect: true)

private func askTwo(_ q: RequestQueue) async -> BoardResponse? {
    await q.ask(shape: .question(options: [2, 2], multi: [false, true])) { id in
        [.question(id: id, index: 0, count: 2, project: "p", question: colour),
         .question(id: id, index: 1, count: 2, project: "p", question: fruit)]
    }
}

@Test func otherAnswerIsStoredForTheShownQuestion() async {
    let r = rig(engine: FakeEngine(finals: ["Sầu riêng"]))
    async let answer = askTwo(r.requests)
    await settle()
    let id = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .other(question: 1), target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final("Sầu riêng"), .done("Added as your answer")])
    await r.requests.handle(.answers(id: id, masks: [0b1, 0x80 | 0b1]))
    #expect(await answer == .answers([0b1, 0x81], others: [1: "Sầu riêng"]))
    #expect(r.typer.typed.isEmpty)                                // an answer is never typed
}

@Test func otherForAGoneQuestionFails() async {
    let r = rig(engine: FakeEngine(finals: ["Tím", "Tím"]))
    await r.hub.input(.voiceStart(voice: 8, purpose: .other(question: 0), target: 12345))
    async let answer = askTwo(r.requests)
    await settle()
    let id = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .other(question: 0), target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.requests.handle(.answers(id: id, masks: [0b1, 0b1]))    // answered (or gone) before Send
    #expect(await answer == .answers([0b1, 0b1]))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(8) == [.error("The question is no longer on the board")])
    #expect(await r.sent.updates(9).last == .error("The question is no longer on the board"))
}

@Test func denyReasonDeniesTheShownPermission() async {
    let r = rig(engine: FakeEngine(finals: ["dùng pnpm thay vì npm"]))
    async let decision = r.requests.ask(project: "p", tool: "Bash", summary: "npm test")
    await settle()
    let id = await r.sent.permissionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .denyReason, target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(await decision == .denyWithReason("dùng pnpm thay vì npm"))
    await settle()
    #expect(await r.sent.updates(9) == [.final("dùng pnpm thay vì npm"), .done("Denied with your reason")])
    await r.hub.input(.voiceStart(voice: 10, purpose: .denyReason, target: id))   // no longer shown
    await settle()
    #expect(await r.sent.updates(10) == [.error("The request is no longer on the board")])
}

// The board shows exactly what is typed or answered: the transcript is cleaned (VoiceText.forTyping) first.

@Test func commandTextIsCleanedBeforeItIsShownAndTyped() async {
    let r = rig(engine: FakeEngine(finals: ["/\u{200B}chạy\u{00AD} các\u{2028}bài \u{201C}kiểm tra\u{201D}\u{FEFF}"]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    let shown = "chạy các bài \"kiểm tra\""
    #expect(await r.sent.updates(9) == [.final(shown), .done("Sent to esp32")])
    #expect(r.typer.typed == [shown])
}

@Test func otherAnswerIsCleanedBeforeItIsStored() async {
    let r = rig(engine: FakeEngine(finals: ["  #Sầu\u{200D} riêng\n"]))
    async let answer = askTwo(r.requests)
    await settle()
    let id = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .other(question: 1), target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final("Sầu riêng"), .done("Added as your answer")])
    await r.requests.handle(.answers(id: id, masks: [0b1, 0x80]))
    #expect(await answer == .answers([0b1, 0x80], others: [1: "Sầu riêng"]))
}

@Test func denyReasonIsCleanedBeforeItIsSent() async {
    let r = rig(engine: FakeEngine(finals: ["!dùng\u{2028}pnpm\u{200B}"]))
    async let decision = r.requests.ask(project: "p", tool: "Bash", summary: "npm test")
    await settle()
    let id = await r.sent.permissionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .denyReason, target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(await decision == .denyWithReason("dùng pnpm"))
    await settle()
    #expect(await r.sent.updates(9) == [.final("dùng pnpm"), .done("Denied with your reason")])
}

@Test func blankOtherOrDenyIsNeverForwarded() async {
    let r = rig(engine: FakeEngine(finals: [" \u{200B}\n\t ", "  /  "]))
    async let decision = r.requests.ask(project: "p", tool: "Bash", summary: "npm test")
    await settle()
    let permission = await r.sent.permissionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .denyReason, target: permission))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final(""), .error("Nothing to send")])
    #expect(await r.requests.shownShape(id: permission) != nil)      // still waiting on the board
    await r.requests.handle(.choice(id: permission, .deny))
    #expect(await decision == .deny)

    async let answer = askTwo(r.requests)
    await settle()
    let question = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 10, purpose: .other(question: 0), target: question))
    await r.hub.input(.voiceStop(voice: 10))
    await r.hub.input(.voiceSend(voice: 10))
    await settle()
    #expect(await r.sent.updates(10) == [.final(""), .error("Nothing to send")])
    await r.requests.handle(.answers(id: question, masks: [0b1, 0b1]))
    #expect(await answer == .answers([0b1, 0b1]))                    // no Other text was stored
}

/// The daemon's wiring (main.swift): voice inputs and audio packets go through ONE AsyncStream of events drained by
/// one task, so a stop never overtakes audio and packets sent while start awaits engine.begin are kept, in order.
@Test func serialFeedKeepsAudioSentWhileTheEngineStarts() async {
    let r = rig(engine: FakeEngine(finals: ["xin chào"], beginDelay: .milliseconds(100)))
    let (events, feed) = AsyncStream<@Sendable () async -> Void>.makeStream()
    let drain = Task { for await event in events { await event() } }
    let hub = r.hub
    feed.yield { await hub.input(.voiceStart(voice: 9, purpose: .command, target: 7)) }
    for seq in UInt8(0)..<3 { feed.yield { await hub.audio(packet(seq)) } }   // while begin is still pending
    feed.yield { await hub.input(.voiceStop(voice: 9)) }
    feed.yield { await hub.audio(packet(3)) }                                  // after stop: ignored
    feed.yield { await hub.boardDisconnected() }                               // link drop ends the capture
    feed.yield { await hub.input(.voiceSend(voice: 9)) }
    feed.finish()
    await drain.value
    #expect(r.engine!.streams[0].fed == 6)
    #expect(await r.sent.updates(9) == [.final("xin chào")])
    #expect(r.engine!.streams[0].cancelled && r.typer.typed.isEmpty)
}
