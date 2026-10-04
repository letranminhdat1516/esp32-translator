import ClaudeRelay
import Foundation
import Testing
@testable import ClaudeBoardCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

private func until(_ seconds: Double = 5, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}

private func wired() -> (RelayLink, BoardRouter, RelayVoiceEngine, Log) {
    let log = Log()
    let link = RelayLink()
    let router = BoardRouter(send: { path, m in
        if path == .relay { link.sendToBoard(m) } else { log.add("direct \(m.encode().first!)") }
    })
    router.onInput = { log.add("input \($0)") }
    router.onConnectionChange = { log.add($0 ? "up" : "down") }
    let voice = RelayVoiceEngine(send: { link.send($0) })
    link.connect(router: router, voice: voice)
    link.attach { log.add("frame \($0.encode().map { String(format: "%02x", $0) }.joined())") }
    return (link, router, voice, log)
}

@Test func boardLinkFramesDriveTheRelayPath() async {
    let (link, router, _, log) = wired()
    link.relayConnected(true)
    link.frame(.boardLink(true)); router.flush()
    #expect(router.activePath == .relay && log.all == ["up"])
    router.send(.cancel(id: 7))
    #expect(log.all.last == "frame 010207000000")         // toBoard: the encoded message, unchanged
    link.frame(.fromBoard(Data([7, 0, 0, 0, 1]))); router.flush()
    #expect(log.all.last == "input \(BoardInput.choice(id: 7, .allow))")
    link.frame(.boardLink(false)); router.flush()
    #expect(router.activePath == nil && log.all.last == "down")
}

@Test func unreadableBoardInputIsDropped() {
    let (link, router, _, log) = wired()
    link.frame(.boardLink(true)); router.flush()
    link.frame(.fromBoard(Data([0, 0, 0, 0, 0x99]))); router.flush()
    #expect(!log.all.contains { $0.hasPrefix("input") })
}

@Test func relayGoneTakesThePathAndVoiceDown() async {
    let (link, router, voice, _) = wired()
    link.frame(.boardLink(true))
    link.frame(.voiceStatus(nil)); router.flush()
    #expect(await voice.prepare() == nil)
    link.relayConnected(false); router.flush()
    #expect(router.activePath == nil)
    #expect(await voice.prepare() == RelayVoiceEngine.notConnected)
}

@Test func transcriptsReachTheVoiceEngine() async throws {
    let (link, _, voice, log) = wired()
    let stream = try await voice.begin { _ in }
    #expect(log.all.last == "frame 1001000000")           // voiceBegin(1) through the attached server
    async let text = stream.finish()
    try await Task.sleep(for: .milliseconds(50))
    link.frame(.transcript(1, final: true, "Chạy test"))
    #expect(await text == "Chạy test")
}

private final class Ifs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TailscaleAddress.Interface] = []
    var value: [TailscaleAddress.Interface] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
}

@Test func watcherReportsOnlyChanges() {
    let ifs = Ifs()
    let seen = Log()
    let w = RelayAddressWatcher(interfaces: { ifs.value }, onChange: { seen.add($0 ?? "none") })
    w.refresh()                                           // first look always reports
    ifs.value = [.init(name: "utun3", address: "100.101.102.103")]
    w.refresh(); w.refresh()
    ifs.value = [.init(name: "utun3", address: "100.101.102.104")]
    w.refresh()
    ifs.value = [.init(name: "en0", address: "100.101.102.104")]   // not a tunnel: not Tailscale
    w.refresh()
    w.forceNext(); w.refresh()                            // after a listener failure: report again
    #expect(seen.all == ["none", "100.101.102.103", "100.101.102.104", "none", "none"])
}

@Test func addressGoneStopsTheListener() async throws {
    // A real server on loopback (tests never need Tailscale), a real client, then the address goes away
    let secret = RelaySecret.random()
    let (link, router, _, _) = wired()
    let host = RelayHost(secret: secret, link: link, port: 0, allowRemote: { $0 == "127.0.0.1" })
    let port = Log()
    host.onListening = { port.add("\($0)") }
    host.addressChanged("127.0.0.1")
    #expect(await until { !port.all.isEmpty })
    let client = RelayClient(pairing: RelayPairing(host: "127.0.0.1", port: UInt16(port.all[0])!, secret: secret))
    let states = Log()
    client.onState = { states.add("\($0)") }
    client.connect()
    defer { client.disconnect() }
    #expect(await until { states.all.contains("authenticated") })
    client.send(.boardLink(true))
    #expect(await until { router.activePath == .relay })
    host.addressChanged(nil)                              // Tailscale went down: no listener, no relay path
    #expect(await until { router.activePath == nil })
    #expect(await until { states.all.last?.hasPrefix("failed") ?? false })
}

@Test func listenerFailureDetachesAndReports() async throws {
    // A second host on the port the first one holds cannot listen (no address reuse): it reports the failure,
    // and frames for the iPhone go nowhere
    let secret = RelaySecret.random()
    let (link1, _, _, _) = wired()
    let first = RelayHost(secret: secret, link: link1, port: 0, allowRemote: { _ in true })
    let port = Log()
    first.onListening = { port.add("\($0)") }
    first.addressChanged("127.0.0.1")
    #expect(await until { !port.all.isEmpty })

    let (link2, _, _, log2) = wired()
    let second = RelayHost(secret: secret, link: link2, port: UInt16(port.all[0])!, allowRemote: { _ in true })
    let events = Log()
    second.onListening = { _ in events.add("listening") }
    second.onListenerFailed = { events.add("failed") }
    second.addressChanged("127.0.0.1")
    #expect(await until { events.all == ["failed"] })
    let before = log2.all.count
    link2.send(.voiceBegin(1))
    #expect(log2.all.count == before)                    // the test's own attach was replaced, then detached
    first.addressChanged(nil)
}

@Test func backoffDoublesUpToTheLimitAndResets() {
    let b = RelayBackoff()
    let delays = (0..<9).map { _ in b.next() }
    #expect(delays == [5, 10, 20, 40, 80, 160, 300, 300, 300])
    #expect(b.failures == 9)
    b.reset()
    #expect(b.failures == 0 && b.next() == 5)
}
