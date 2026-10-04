import Foundation
import Network
import Testing
@testable import ClaudeRelay

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}

func eventually(_ seconds: Double = 5, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private let secret = RelaySecret.random()

private func loopbackPolicy(maxFailures: Int = 5, lockout: TimeInterval = 60,
                            allow: @escaping @Sendable (String) -> Bool = { $0 == "127.0.0.1" }) -> RelayServer.Policy {
    var p = RelayServer.Policy(host: "127.0.0.1", port: 0, allowRemote: allow)
    p.maxFailures = maxFailures
    p.lockout = lockout
    p.handshakeTimeout = 2
    return p
}

/// A started server, its bound port, and what it reported
private func startServer(_ policy: RelayServer.Policy = loopbackPolicy())
    async throws -> (RelayServer, UInt16, Box<Bool>, Box<RelayFrame>) {
    let server = RelayServer(secret: secret, policy: policy)
    let relays = Box<Bool>(), frames = Box<RelayFrame>()
    server.onRelay = { relays.add($0) }
    server.onFrame = { frames.add($0) }
    let port: UInt16? = await withCheckedContinuation { c in
        do { try server.start { c.resume(returning: $0) } } catch { c.resume(returning: nil) }
    }
    return (server, try #require(port), relays, frames)
}

private func client(_ port: UInt16, host: String = "127.0.0.1", secret s: RelaySecret = secret)
    -> (RelayClient, Box<RelayClient.State>, Box<RelayFrame>) {
    let c = RelayClient(pairing: RelayPairing(host: host, port: port, secret: s), handshakeTimeout: 2)
    let states = Box<RelayClient.State>(), frames = Box<RelayFrame>()
    c.onState = { states.add($0) }
    c.onFrame = { frames.add($0) }
    c.connect()
    return (c, states, frames)
}

@Test func authenticatedRelayExchangesFrames() async throws {
    let (server, port, relays, serverFrames) = try await startServer()
    defer { server.stop() }
    let (c, states, clientFrames) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) && relays.all == [true] })
    c.send(.fromBoard(Data([9, 0, 0, 0, 0x32])))
    c.send(.boardLink(true))
    #expect(await eventually { serverFrames.all == [.fromBoard(Data([9, 0, 0, 0, 0x32])), .boardLink(true)] })
    server.send(.toBoard(Data([2, 7, 0, 0, 0])))
    #expect(await eventually { clientFrames.all == [.toBoard(Data([2, 7, 0, 0, 0]))] })
    c.disconnect()
    #expect(await eventually { relays.all == [true, false] })
}

@Test func wrongSecretNeverReachesTheRelay() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (c, states, _) = client(port, secret: RelaySecret.random())
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    c.send(.fromBoard(Data([9, 0, 0, 0, 0x32])))
    try await Task.sleep(for: .milliseconds(200))
    #expect(relays.all.isEmpty && frames.all.isEmpty)
}

/// A raw WebSocket client that skips the handshake
private func rawConnection(_ port: UInt16) -> NWConnection {
    let c = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/relay")!),
                         using: WebSocketIO.parameters(serverKeepalive: false))
    c.start(queue: DispatchQueue(label: "raw"))
    return c
}

@Test func framesBeforeAuthCloseTheConnection() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let raw = rawConnection(port)
    defer { raw.cancel() }
    let ended = Box<Bool>()
    // First message from the server is the challenge; answer with a data frame instead of auth
    WebSocketIO.receive(on: raw) { _ in
        WebSocketIO.send(RelayFrame.fromBoard(Data([9, 0, 0, 0, 0x33])).encode(), on: raw)
        WebSocketIO.receive(on: raw) { r in if case .end = r { ended.add(true) } }
    }
    #expect(await eventually { !ended.all.isEmpty })
    #expect(relays.all.isEmpty && frames.all.isEmpty)
}

/// A raw connection that runs the handshake itself, then sends `bytes` unchecked (RelayClient refuses to)
private func rawAuthenticated(_ port: UInt16, beforeAuth: @escaping @Sendable () -> Void = {},
                              welcomed: @escaping @Sendable (Bool) -> Void = { _ in },
                              then bytes: Data) -> NWConnection {
    let raw = rawConnection(port)
    let hs = HandshakeBox(ClientHandshake(secret: secret))
    WebSocketIO.receive(on: raw) { r in                  // challenge
        guard case .binary(let d) = r, let f = RelayFrame.decode(d, from: .mac),
              case .send(let auth) = hs.receive(f) else { return }
        beforeAuth()
        WebSocketIO.send(auth.encode(), on: raw)
        WebSocketIO.receive(on: raw) { r in              // welcome
            guard case .binary(let d) = r, let f = RelayFrame.decode(d, from: .mac),
                  hs.receive(f) == .authenticated else { welcomed(false); return }
            welcomed(true)
            WebSocketIO.send(bytes, on: raw)
        }
    }
    return raw
}

private final class HandshakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hs: ClientHandshake
    init(_ hs: ClientHandshake) { self.hs = hs }
    func receive(_ f: RelayFrame) -> ClientHandshake.Step { lock.withLock { hs.receive(f) } }
}

@Test func macFramesFromThePhoneCloseTheConnection() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let raw = rawAuthenticated(port, then: RelayFrame.toBoard(Data([0, 1, 0, 0, 0])).encode())  // only the Mac may send this
    defer { raw.cancel() }
    #expect(await eventually { relays.all == [true, false] })
    #expect(frames.all.isEmpty)
}

@Test func clientDropsFramesTheMacWouldRefuse() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) })
    c.send(.toBoard(Data([0, 1, 0, 0, 0])))              // Mac-direction: dropped, not sent
    c.send(.voiceStatus(""))                             // malformed: dropped, not sent
    c.send(.boardLink(true))
    #expect(await eventually { frames.all == [.boardLink(true)] })
    #expect(relays.all == [true] && states.all.last == .authenticated)
}

@Test func silentClientsTimeOut() async throws {
    let (server, port, relays, _) = try await startServer()
    defer { server.stop() }
    let raw = rawConnection(port)
    defer { raw.cancel() }
    let ended = Box<Bool>()
    WebSocketIO.receive(on: raw) { _ in                  // the challenge; then say nothing
        WebSocketIO.receive(on: raw) { r in if case .end = r { ended.add(true) } }
    }
    #expect(await eventually(4) { !ended.all.isEmpty })  // handshakeTimeout 2 s in the test policy
    #expect(relays.all.isEmpty)
}

@Test func lockoutAfterRepeatedFailures() async throws {
    let (server, port, relays, _) = try await startServer(loopbackPolicy(maxFailures: 2, lockout: 2))
    defer { server.stop() }
    for _ in 0..<2 {
        let (bad, states, _) = client(port, secret: RelaySecret.random())
        #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
        bad.disconnect()
    }
    let (locked, lockedStates, _) = client(port)        // the right secret, but the port is locked
    #expect(await eventually { lockedStates.all.contains { if case .failed = $0 { true } else { false } } })
    locked.disconnect()
    #expect(relays.all.isEmpty)
    try await Task.sleep(for: .milliseconds(2200))
    let (good, goodStates, _) = client(port)
    defer { good.disconnect() }
    #expect(await eventually { goodStates.all.contains(.authenticated) })
}

@Test func remotePolicyRefuses() async throws {
    let (server, port, relays, _) = try await startServer(loopbackPolicy(allow: { _ in false }))
    defer { server.stop() }
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    #expect(relays.all.isEmpty)
}

@Test func bindsOnlyTheGivenAddress() async throws {
    // Bound to 127.0.0.1: the same port on ::1 (another address of this Mac) has no listener
    let (server, port, relays, _) = try await startServer(loopbackPolicy(allow: { _ in true }))
    defer { server.stop() }
    let (c, states, _) = client(port, host: "::1")
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    #expect(relays.all.isEmpty)
}

@Test func newRelayReplacesTheOldOne() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (first, firstStates, _) = client(port)
    defer { first.disconnect() }
    #expect(await eventually { firstStates.all.contains(.authenticated) })
    let (second, secondStates, secondFrames) = client(port)
    defer { second.disconnect() }
    #expect(await eventually { secondStates.all.contains(.authenticated) })
    #expect(await eventually { firstStates.all.last.map { if case .failed = $0 { true } else { false } } ?? false })
    #expect(relays.all == [true, true])                  // no "gone" for the replaced one
    server.send(.voiceBegin(4))
    #expect(await eventually { secondFrames.all == [.voiceBegin(4)] })
    second.send(.boardLink(true))
    #expect(await eventually { frames.all == [.boardLink(true)] })
}

// MARK: - Fix round 1: per-remote lockout, pending cap, stop, listener lifecycle

private func gate(maxFailures: Int = 5) -> HandshakeGate {
    HandshakeGate(maxFailures: maxFailures, failureWindow: 60, lockout: 60, maxPending: 4, maxPendingPerRemote: 2)
}

@Test func oneDevicesFailuresDoNotLockOutAnother() {
    var g = gate()
    let t = Date()
    var locked: [Bool] = []
    for i in 0..<5 { locked.append(g.fail("100.64.0.2", now: t + Double(i))) }
    #expect(locked == [false, false, false, false, true])              // the fifth within 60 s locks B
    let b = g.admit("100.64.0.2", now: t + 5)
    let a = g.admit("100.64.0.1", now: t + 5)
    #expect(b == .locked)
    #expect(a == nil)                                                  // A is unaffected
    g.release("100.64.0.1")
    let bLater = g.admit("100.64.0.2", now: t + 65)
    #expect(bLater == nil)                                             // B again after the lockout
}

@Test func failuresOutsideTheWindowDoNotCount() {
    var g = gate(maxFailures: 2)
    let t = Date()
    let first = g.fail("100.64.0.2", now: t)
    let second = g.fail("100.64.0.2", now: t + 61)                     // the first one has aged out
    let admitted = g.admit("100.64.0.2", now: t + 62)
    #expect(!first && !second && admitted == nil)
}

@Test func pendingConnectionsAreCappedInTotalAndPerRemote() {
    var g = gate()
    let t = Date()
    let r1 = [g.admit("a", now: t), g.admit("a", now: t), g.admit("a", now: t)]
    #expect(r1 == [nil, nil, .busy])                                   // 2 per remote
    let r2 = [g.admit("b", now: t), g.admit("b", now: t), g.admit("c", now: t)]
    #expect(r2 == [nil, nil, .busy])                                   // 4 in total
    g.release("a")
    let r3 = g.admit("c", now: t)
    #expect(r3 == nil)
    #expect(g.pendingCount == 4)
}

/// A raw connection's first message: the challenge (true), or the end without one (false)
private func firstMessage(_ raw: NWConnection, into box: Box<Bool>) {
    WebSocketIO.receive(on: raw) { r in
        if case .binary = r { box.add(true) } else { box.add(false) }
    }
}

@Test func silentConnectionsBeyondTheCapAreRefused() async throws {
    let (server, port, _, _) = try await startServer()
    defer { server.stop() }
    let first = Box<Bool>()
    let silent = [rawConnection(port), rawConnection(port)]           // the per-remote cap (2) from 127.0.0.1
    defer { silent.forEach { $0.cancel() } }
    silent.forEach { firstMessage($0, into: first) }
    #expect(await eventually { first.all == [true, true] })
    let extra = rawConnection(port)
    defer { extra.cancel() }
    let extraFirst = Box<Bool>()
    firstMessage(extra, into: extraFirst)
    #expect(await eventually { extraFirst.all == [false] })           // refused: no challenge
    silent[0].cancel()                                                 // a slot frees up once the server sees it
    #expect(await eventually {
        let (c, states, _) = client(port)
        defer { c.disconnect() }
        let end = Date().addingTimeInterval(1)
        while Date() < end, !states.all.contains(where: { $0 != .connecting && $0 != .idle }) { usleep(10_000) }
        return states.all.contains(.authenticated)
    })
}

@Test func stopMidHandshakeNeverAuthenticates() async throws {
    let (server, port, relays, frames) = try await startServer()
    let welcomed = Box<Bool>()
    // stop() lands between the challenge and the (valid) auth
    let raw = rawAuthenticated(port, beforeAuth: { server.stop() }, welcomed: { welcomed.add($0) },
                               then: RelayFrame.boardLink(true).encode())
    defer { raw.cancel() }
    #expect(await eventually { welcomed.all == [false] })             // closed instead of welcomed
    #expect(relays.all.isEmpty && frames.all.isEmpty)
}

@Test func aSecondServerOnTheSamePortFails() async throws {
    let (server, port, _, _) = try await startServer()
    defer { server.stop() }
    var p = loopbackPolicy()
    p.port = port
    let second = RelayServer(secret: secret, policy: p)
    defer { second.stop() }
    let bound: UInt16? = await withCheckedContinuation { c in
        do { try second.start { c.resume(returning: $0) } } catch { c.resume(returning: nil) }
    }
    #expect(bound == nil)
}

@Test func startingAgainReplacesTheListener() async throws {
    let (server, oldPort, _, _) = try await startServer()
    defer { server.stop() }
    let newPort: UInt16? = await withCheckedContinuation { c in
        do { try server.start { c.resume(returning: $0) } } catch { c.resume(returning: nil) }
    }
    let port = try #require(newPort)
    let (old, oldStates, _) = client(oldPort)
    defer { old.disconnect() }
    #expect(await eventually { oldStates.all.contains { if case .failed = $0 { true } else { false } } })
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) })
}

@Test func droppedConnectionsAreNotHandshakeFailures() async throws {
    let (server, port, _, _) = try await startServer(loopbackPolicy(maxFailures: 1))   // one definite failure locks
    defer { server.stop() }
    let first = Box<Bool>()
    let raw = rawConnection(port)
    firstMessage(raw, into: first)
    #expect(await eventually { first.all == [true] })
    raw.cancel()                                                       // connect, get the challenge, hang up
    try await Task.sleep(for: .milliseconds(200))
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) })
}
