import Foundation
import Testing
@testable import ClaudeBoardCore

/// Router with every callback recorded as one ordered log
private final class RouterLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
    func clear() { lock.withLock { items.removeAll() } }
}

private func makeRouter() -> (BoardRouter, RouterLog) {
    let log = RouterLog()
    let r = BoardRouter(send: { path, m in log.add("send \(path.rawValue) \(m.encode().first!)") })
    r.onConnectionChange = { log.add($0 ? "up" : "down") }
    r.onInput = { log.add("input \($0)") }
    r.onVoiceAudio = { log.add("audio \($0.count)") }
    return (r, log)
}

private let mode = BoardInput.mode(.claude)

@Test func prefersDirect() {
    let (r, log) = makeRouter()
    r.pathReady(.relay, true); r.flush()
    #expect(r.activePath == .relay && log.all == ["up"])
    r.pathReady(.direct, true); r.flush()
    #expect(r.activePath == .direct)
    #expect(log.all == ["up", "down", "up"])            // a path change is a reconnect for everyone downstream
    log.clear()
    r.send(.sessionsClear)
    #expect(log.all == ["send direct 6"])
}

@Test func fallsBackToTheRelayWhenDirectDrops() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    r.pathReady(.direct, false); r.flush()
    #expect(r.activePath == .relay && log.all == ["down", "up"])
    log.clear()
    r.send(.cancel(id: 7))
    #expect(log.all == ["send relay 2"])
}

@Test func relayInputWhileDirectMeansTheBoardMovedOn() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    // The board lost the Mac first and reports its mode over the relay; the Mac has not noticed yet
    r.input(mode, from: .relay); r.flush()
    #expect(r.activePath == .relay)
    #expect(log.all == ["down", "up", "input \(mode)"])   // resync on the relay, then the mode (hub order)
    log.clear()
    r.pathReady(.direct, false); r.flush()               // the BLE loss arrives: nothing changes
    #expect(log.all.isEmpty && r.activePath == .relay)
}

@Test func directReturnTakesOver() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    r.input(mode, from: .relay); r.pathReady(.direct, false); r.flush()
    log.clear()
    r.pathReady(.direct, true); r.flush()                // reconnected: the board prefers it too
    #expect(r.activePath == .direct && log.all == ["down", "up"])
}

@Test func directInputClearsAStaleDirect() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    r.input(mode, from: .relay); r.flush()
    log.clear()
    r.input(mode, from: .direct); r.flush()              // the board is back on direct without a reconnect event
    #expect(r.activePath == .direct && log.all == ["down", "up", "input \(mode)"])
}

@Test func inputFromAPathThatIsNotReadyIsDropped() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.flush()
    log.clear()
    r.input(.choice(id: 5, .allow), from: .relay); r.flush()
    #expect(log.all.isEmpty && r.activePath == .direct)
}

@Test func noPathSendsNothing() {
    let (r, log) = makeRouter()
    #expect(!r.isReady)
    r.send(.sessionsClear)
    #expect(log.all.isEmpty)
    r.pathReady(.relay, true); r.pathReady(.relay, false); r.flush()
    #expect(log.all == ["up", "down"] && !r.isReady)
}

@Test func voiceAudioOnlyFromTheActivePath() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    r.voiceAudio(Data(count: 165), from: .relay)
    r.voiceAudio(Data(count: 85), from: .direct); r.flush()
    #expect(log.all == ["audio 85"])
}

/// Direct and relay ready, the board followed to the relay (direct stale)
private func onTheRelayWithDirectStale() -> (BoardRouter, RouterLog) {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.input(mode, from: .relay); r.flush()
    log.clear()
    return (r, log)
}

private let answering: [BoardInput] = [.choice(id: 5, .allow), .answers(id: 5, masks: [1]), .voiceSend(voice: 3)]

@Test func anAnswerThatSwitchesThePathIsDropped() {
    for input in answering {
        let (r, log) = onTheRelayWithDirectStale()
        r.input(input, from: .direct); r.flush()          // direct takes over, but the answer belongs to the relay's screen
        #expect(r.activePath == .direct && log.all == ["down", "up"], "\(input)")
    }
    let (r, log) = onTheRelayWithDirectStale()
    r.input(.focus(handle: 9), from: .direct); r.flush()  // inputs that cannot answer still arrive
    #expect(log.all == ["down", "up", "input \(BoardInput.focus(handle: 9))"])
}

@Test func onlyTheModeReportFollowsTheBoardToTheRelay() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    for input in answering + [.focus(handle: 9), .voiceCancel(voice: 3)] {
        r.input(input, from: .relay); r.flush()
        #expect(r.activePath == .direct && log.all.isEmpty, "\(input)")
    }
    r.input(mode, from: .relay); r.flush()
    #expect(r.activePath == .relay && log.all == ["down", "up", "input \(mode)"])
}

@Test func aRepeatedDirectReadyDoesNotClearStale() {
    let (r, log) = onTheRelayWithDirectStale()
    r.pathReady(.direct, true); r.flush()                // no change in readiness: the board is still on the relay
    #expect(r.activePath == .relay && log.all.isEmpty)
    r.send(.sessionsClear)
    #expect(log.all == ["send relay 6"])
}
