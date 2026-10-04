import ClaudeRelay
import Foundation
import Testing
@testable import ClaudeBoardCore

private final class RelaySent: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RelayFrame] = []
    private var partials: [String] = []
    func add(_ f: RelayFrame) { lock.withLock { frames.append(f) } }
    func partial(_ s: String) { lock.withLock { partials.append(s) } }
    var all: [RelayFrame] { lock.withLock { frames } }
    var said: [String] { lock.withLock { partials } }
}

@Test func statusIsWhatPrepareReports() async {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    #expect(await e.prepare() == RelayVoiceEngine.notConnected)
    e.setStatus(nil)
    #expect(await e.prepare() == nil)
    e.setStatus("Allow Speech Recognition for Live Translator on the iPhone")
    #expect(await e.prepare() == "Allow Speech Recognition for Live Translator on the iPhone")
}

@Test func beginPartialsAndFinal() async throws {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    let stream = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let session)? = sent.all.first else { Issue.record("no begin"); return }
    stream.feed([1, 2, 3])                                // audio never crosses the relay: nothing is sent
    e.frame(.transcript(session, final: false, "xin"))
    e.frame(.transcript(session, final: false, "xin chào"))
    async let text = stream.finish()
    try await Task.sleep(for: .milliseconds(50))
    #expect(sent.all == [.voiceBegin(session), .voiceFinish(session)])
    e.frame(.transcript(session, final: true, "Xin chào."))
    #expect(await text == "Xin chào.")
    #expect(sent.said == ["xin", "xin chào"])
}

@Test func staleTranscriptsAreIgnored() async throws {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) }, finalTimeout: .milliseconds(300))
    let first = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let old)? = sent.all.last else { return }
    await first.cancel()
    let second = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let new)? = sent.all.last else { return }
    #expect(old != new && sent.all.contains(.voiceCancel(old)))
    e.frame(.transcript(old, final: false, "old words"))
    e.frame(.transcript(old, final: true, "old final"))
    async let text = second.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.frame(.transcript(new, final: true, "new final"))
    #expect(await text == "new final")
    #expect(sent.said.isEmpty)
}

@Test func finishTimesOutToEmpty() async throws {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) }, finalTimeout: .milliseconds(200))
    let s = try await e.begin { _ in }
    #expect(await s.finish() == "")                       // the board then shows "Didn't catch that"
}

@Test func failedSessionEndsEmpty() async throws {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    let s = try await e.begin { _ in }
    guard case .voiceBegin(let id)? = sent.all.first else { return }
    async let text = s.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.frame(.voiceFailed(id, "Transcription did not start"))
    #expect(await text == "")
}

@Test func relayGoneEndsTheStream() async throws {
    let sent = RelaySent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    e.setStatus(nil)
    let s = try await e.begin { _ in }
    async let text = s.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.relayGone()
    #expect(await text == "")
    #expect(await e.prepare() == RelayVoiceEngine.notConnected)
}

@Test func routedEngineFollowsThePath() async throws {
    let local = FakeEngine(finals: ["local"])
    let relayFrames = RelaySent()
    let relay = RelayVoiceEngine(send: { relayFrames.add($0) })
    let path = PathBox()
    let routed = RoutedVoiceEngine(local: local, relay: relay, path: { path.value })
    path.value = .relay
    #expect(await routed.prepare() == RelayVoiceEngine.notConnected)
    relay.setStatus(nil)
    #expect(await routed.prepare() == nil)
    _ = try await routed.begin { _ in }
    #expect(local.streams.isEmpty && relayFrames.all.count == 1)
    path.value = .direct
    local.unavailable = "Allow Speech Recognition for claude-board in System Settings"
    #expect(await routed.prepare() == "Allow Speech Recognition for claude-board in System Settings")
    local.unavailable = nil
    #expect(await routed.prepare() == nil)
    local.unavailable = "changed"                          // the Mac's own readiness is cached once ready
    #expect(await routed.prepare() == nil)
    _ = try await routed.begin { _ in }
    #expect(local.streams.count == 1)
    let noLocal = RoutedVoiceEngine(local: nil, relay: relay, path: { .direct })
    #expect(await noLocal.prepare() == "Voice needs macOS 26 on the Mac")
}

private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var p: BoardPath?
    var value: BoardPath? { get { lock.withLock { p } } set { lock.withLock { p = newValue } } }
}
