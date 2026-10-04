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
private func rawAuthenticated(_ port: UInt16, then bytes: Data) -> NWConnection {
    let raw = rawConnection(port)
    let hs = HandshakeBox(ClientHandshake(secret: secret))
    WebSocketIO.receive(on: raw) { r in                  // challenge
        guard case .binary(let d) = r, let f = RelayFrame.decode(d, from: .mac),
              case .send(let auth) = hs.receive(f) else { return }
        WebSocketIO.send(auth.encode(), on: raw)
        WebSocketIO.receive(on: raw) { r in              // welcome
            guard case .binary(let d) = r, let f = RelayFrame.decode(d, from: .mac),
                  hs.receive(f) == .authenticated else { return }
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
