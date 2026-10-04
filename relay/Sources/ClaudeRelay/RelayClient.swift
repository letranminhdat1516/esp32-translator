import Foundation
import Network

/// The iPhone's end: connects to the pairing's ws:// URL, runs the handshake (and checks the Mac's proof), then
/// passes Mac-direction frames up. A WebSocket ping every `pingInterval` (≥ 30 s; no other polling); no pong within
/// 15 s ends the connection. Reconnecting is the caller's job (ClaudeRelayService: backoff + path changes).
public final class RelayClient: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, connecting, authenticated, failed(String) }

    public var onState: (@Sendable (State) -> Void)?
    public var onFrame: (@Sendable (RelayFrame) -> Void)?

    private let pairing: RelayPairing
    private let pingInterval: TimeInterval
    private let handshakeTimeout: TimeInterval
    private let queue = DispatchQueue(label: "relay.client")
    private var connection: NWConnection?
    private var handshake: ClientHandshake
    private var authenticated = false
    private var generation = 0
    private var state = State.idle

    public init(pairing: RelayPairing, pingInterval: TimeInterval = 60, handshakeTimeout: TimeInterval = 10) {
        self.pairing = pairing
        self.pingInterval = max(30, pingInterval)
        self.handshakeTimeout = handshakeTimeout
        handshake = ClientHandshake(secret: pairing.secret)
    }

    public func connect() {
        queue.async { [self] in
            guard connection == nil else { return }
            generation += 1
            let gen = generation
            handshake = ClientHandshake(secret: pairing.secret)
            authenticated = false
            let c = NWConnection(to: .url(pairing.webSocketURL), using: WebSocketIO.parameters(serverKeepalive: false))
            connection = c
            c.stateUpdateHandler = { [weak self] s in
                guard let self, gen == self.generation else { return }
                switch s {
                case .ready: self.receive(c, gen)
                case .waiting(let e): self.finish(.failed("Mac unreachable: \(e)"))   // the caller retries, with backoff
                case .failed(let e): self.finish(.failed("\(e)"))
                default: break
                }
            }
            report(.connecting)
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                guard let self, gen == self.generation, !self.authenticated else { return }
                self.finish(.failed("The Mac did not answer the pairing check"))
            }
        }
    }

    public func disconnect() { queue.async { self.finish(.idle) } }

    public func send(_ frame: RelayFrame) {
        queue.async { [self] in
            // A frame the Mac would refuse (malformed, Mac-direction) would close the connection: dropped instead
            guard authenticated, let c = connection, let data = frame.wire(from: .phone) else { return }
            WebSocketIO.send(data, on: c)
        }
    }

    private func receive(_ c: NWConnection, _ gen: Int) {
        WebSocketIO.receive(on: c) { [weak self] r in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch r {
                case .end: self.finish(.failed("Connection to the Mac closed"))
                case .control: self.receive(c, gen)
                case .binary(let data):
                    guard let frame = RelayFrame.decode(data, from: .mac) else {
                        self.finish(.failed("Unexpected data from the Mac"))
                        return
                    }
                    if self.authenticated {
                        self.onFrame?(frame)
                    } else {
                        switch self.handshake.receive(frame) {
                        case .send(let reply): WebSocketIO.send(reply.encode(), on: c)
                        case .authenticated:
                            self.authenticated = true
                            self.report(.authenticated)
                            self.schedulePing(c, gen)
                        case .rejected:
                            self.finish(.failed("Pairing check failed: scan the Mac's QR code again"))
                            return
                        }
                    }
                    self.receive(c, gen)
                }
            }
        }
    }

    private func schedulePing(_ c: NWConnection, _ gen: Int) {
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self, gen == self.generation, self.authenticated else { return }
            let answered = Flag()
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            meta.setPongHandler(self.queue) { _ in answered.set() }
            c.send(content: Data(), contentContext: .init(identifier: "ping", metadata: [meta]), isComplete: true,
                   completion: .contentProcessed { _ in })
            self.queue.asyncAfter(deadline: .now() + 15) {
                if gen == self.generation, !answered.value { self.finish(.failed("No answer from the Mac")) }
            }
            self.schedulePing(c, gen)
        }
    }

    private func finish(_ s: State) {
        generation += 1
        connection?.cancel()
        connection = nil
        authenticated = false
        report(s)
    }

    private func report(_ s: State) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
