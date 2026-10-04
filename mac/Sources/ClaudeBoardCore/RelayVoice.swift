import ClaudeRelay
import Foundation

/// Voice when the board is on the relay: the iPhone transcribes the board audio itself and sends text only.
/// To VoiceHub this is just another engine: begin → voiceBegin(session), finish → voiceFinish and wait for the
/// final transcript (empty after `finalTimeout`, a failure or the relay going away), cancel → voiceCancel.
/// Transcripts for any other session are ignored.
public final class RelayVoiceEngine: VoiceEngine, @unchecked Sendable {
    public static let notConnected = "Voice needs the iPhone relay"

    private let sendFrame: @Sendable (RelayFrame) -> Void
    let finalTimeout: Duration
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var status: String? = RelayVoiceEngine.notConnected
    private var nextSession: UInt32 = 1
    private var stream: RelayVoiceStream?

    public init(send: @escaping @Sendable (RelayFrame) -> Void, finalTimeout: Duration = .seconds(15),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sendFrame = send
        self.finalTimeout = finalTimeout
        self.log = log
    }

    /// From the relay's voiceStatus frame (nil = the iPhone can transcribe)
    public func setStatus(_ why: String?) { lock.withLock { status = why } }

    public func prepare() async -> String? { lock.withLock { status } }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        let s = lock.withLock { () -> RelayVoiceStream in
            let id = nextSession
            nextSession = nextSession == .max ? 1 : nextSession + 1
            let s = RelayVoiceStream(session: id, engine: self, onPartial: onPartial)
            stream = s
            return s
        }
        sendFrame(.voiceBegin(s.session))
        return s
    }

    /// transcript / voiceFailed frames from the relay
    public func frame(_ f: RelayFrame) {
        switch f {
        case .transcript(let id, let final, let text):
            current(id)?.transcript(text, final: final)
        case .voiceFailed(let id, let why):
            log("voice over the relay failed: \(why)")
            current(id)?.transcript("", final: true)
        default:
            break
        }
    }

    /// The relay (or its board link) went away: an open capture ends empty
    public func relayGone() {
        let s = lock.withLock { () -> RelayVoiceStream? in
            defer { stream = nil; status = Self.notConnected }
            return stream
        }
        s?.transcript("", final: true)
    }

    fileprivate func send(_ f: RelayFrame) { sendFrame(f) }

    fileprivate func ended(_ s: RelayVoiceStream) { lock.withLock { if stream === s { stream = nil } } }

    fileprivate func timedOut(_ s: RelayVoiceStream) { log("voice over the relay: no final transcript from the iPhone") }

    private func current(_ id: UInt32) -> RelayVoiceStream? { lock.withLock { stream?.session == id ? stream : nil } }
}

final class RelayVoiceStream: VoiceStream, @unchecked Sendable {
    let session: UInt32
    private let engine: RelayVoiceEngine
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var final: String?
    private var waiter: CheckedContinuation<String, Never>?

    init(session: UInt32, engine: RelayVoiceEngine, onPartial: @escaping @Sendable (String) -> Void) {
        self.session = session
        self.engine = engine
        self.onPartial = onPartial
    }

    /// Audio never crosses the relay: the iPhone transcribes what the board sends it
    func feed(_ samples: [Int16]) {}

    func transcript(_ text: String, final isFinal: Bool) {
        if !isFinal {
            if lock.withLock({ final == nil }) { onPartial(text) }
            return
        }
        let w = lock.withLock { () -> CheckedContinuation<String, Never>? in
            guard final == nil else { return nil }
            final = text
            defer { waiter = nil }
            return waiter
        }
        engine.ended(self)
        w?.resume(returning: text)
    }

    func finish() async -> String {
        engine.send(.voiceFinish(session))
        let timeout = engine.finalTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            if self.lock.withLock({ self.final == nil }) { self.engine.timedOut(self) }
            self.transcript("", final: true)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { c in
            let done = lock.withLock { () -> String? in
                if let final { return final }
                waiter = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    func cancel() async {
        engine.send(.voiceCancel(session))
        transcript("", final: true)
    }
}

/// The engine for the active path: the Mac's own dictation (direct) or the iPhone's (relay). The Mac engine's
/// readiness is remembered once it is ready (it asks for permission and installs the model); the relay's
/// changes with the iPhone, so it is asked every time.
public final class RoutedVoiceEngine: VoiceEngine, @unchecked Sendable {
    enum Unavailable: Error { case noLocalEngine }

    private let local: (any VoiceEngine)?
    private let relay: any VoiceEngine
    private let path: @Sendable () -> BoardPath?
    private let lock = NSLock()
    private var localReady = false

    public init(local: (any VoiceEngine)?, relay: any VoiceEngine, path: @escaping @Sendable () -> BoardPath?) {
        self.local = local
        self.relay = relay
        self.path = path
    }

    public func prepare() async -> String? {
        if path() == .relay { return await relay.prepare() }
        guard let local else { return "Voice needs macOS 26 on the Mac" }
        if lock.withLock({ localReady }) { return nil }
        let why = await local.prepare()
        if why == nil { lock.withLock { localReady = true } }
        return why
    }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        if path() == .relay { return try await relay.begin(onPartial: onPartial) }
        guard let local else { throw Unavailable.noLocalEngine }
        return try await local.begin(onPartial: onPartial)
    }
}
