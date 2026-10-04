import Foundation

public enum VoiceConfig {
    /// DictationTranscriber locale. Vietnamese by default; "en_US" would switch voice to English.
    public static let localeIdentifier = "vi_VN"
}

/// Speech to text as the voice hub uses it. The Speech framework engine (macOS 26) lives in the daemon target.
public protocol VoiceEngine: Sendable {
    /// nil when ready (permission granted, model installed); else why voice is unavailable (shown on the board)
    func prepare() async -> String?
    /// Starts one transcription; `onPartial` gets the whole text so far, from any thread
    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream
}

public protocol VoiceStream: AnyObject, Sendable {
    /// 16 kHz mono samples
    func feed(_ samples: [Int16])
    /// Ends the input and returns everything recognised
    func finish() async -> String
    func cancel() async
}

/// One voice capture at a time, from the board's Speak / Other / Deny + why to typed text or an answer.
/// The board streams ADPCM only between voiceStart and voiceStop; the hub answers with partials, one final
/// transcript (VoiceText.forTyping: exactly what Send types) and, after voiceSend for that voice id, done or error.
/// Nothing is typed or answered without voiceSend for the current capture and a non-empty final transcript.
/// Inputs and audio must arrive in board order (the daemon feeds them through one serial stream).
public actor VoiceHub {
    public static let partialInterval: Double = 0.25

    private struct Capture {
        let voice: UInt32
        let purpose: VoicePurpose
        let target: UInt32
        var stream: (any VoiceStream)?
        /// Audio that arrived before the engine was ready
        var pending: [Int16] = []
        var decoder = ADPCMDecoder()
        var stopped = false
        var finishing = false
        var final: String?
        var sending = false
        var lastPartial = ""
        var lastPartialAt = -Double.infinity
    }

    private let engine: (any VoiceEngine)?
    private let typer: any PaneTyping
    private let requests: RequestQueue
    private let target: @Sendable (UInt32) async -> VoiceTarget?
    private let clock: @Sendable () -> Double
    private let maxCapture: Duration
    private let log: @Sendable (String) -> Void
    private var capture: Capture?
    private var engineReady = false

    public init(engine: (any VoiceEngine)?, typer: any PaneTyping, requests: RequestQueue,
                target: @escaping @Sendable (UInt32) async -> VoiceTarget?,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                maxCapture: Duration = .seconds(120),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.engine = engine
        self.typer = typer
        self.requests = requests
        self.target = target
        self.clock = clock
        self.maxCapture = maxCapture
        self.log = log
    }

    public func input(_ input: BoardInput) async {
        switch input {
        case .voiceStart(let voice, let purpose, let target): await start(voice, purpose, target)
        case .voiceStop(let voice): await stop(voice)
        case .voiceCancel(let voice): await cancel(voice)
        case .voiceSend(let voice): await send(voice)
        case .choice, .answers, .mode, .focus: break
        }
    }

    /// One packet from the board's voice characteristic (only used between start and stop)
    public func audio(_ packet: Data) {
        guard var c = capture, !c.stopped else { return }
        let samples = c.decoder.decode(packet)
        if let stream = c.stream { stream.feed(samples) } else { c.pending += samples }
        capture = c
    }

    public func boardDisconnected() async {
        guard let c = capture else { return }
        capture = nil
        await c.stream?.cancel()
    }

    private func post(_ voice: UInt32, _ update: VoiceUpdate) async {
        await requests.post(.voice(id: voice, update))
    }

    private func start(_ voice: UInt32, _ purpose: VoicePurpose, _ targetId: UInt32) async {
        if let old = capture {                      // one capture at a time: a new start replaces the old one
            capture = nil
            await old.stream?.cancel()
        }
        capture = Capture(voice: voice, purpose: purpose, target: targetId)   // audio is buffered from now on
        if let problem = await precheck(purpose, targetId) {
            await fail(voice, problem)
            return
        }
        guard let engine else { return }
        let stream: any VoiceStream
        do {
            stream = try await engine.begin { [weak self] text in
                Task { await self?.partial(voice, text) }
            }
        } catch {
            log("voice \(voice): engine did not start: \(error)")
            await fail(voice, "Speech recognition did not start")
            return
        }
        guard var c = capture, c.voice == voice else {   // cancelled or replaced while the engine started
            await stream.cancel()
            return
        }
        stream.feed(c.pending)
        c.pending = []
        c.stream = stream
        capture = c
        let limit = maxCapture
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.expire(voice)
        }
        if c.stopped { await complete(voice) }
    }

    /// Why this capture cannot be used, checked before the user speaks (Send checks again)
    private func precheck(_ purpose: VoicePurpose, _ id: UInt32) async -> String? {
        guard let engine else { return "Voice needs macOS 26 on the Mac" }
        if !engineReady {
            if let why = await engine.prepare() { return why }   // not cached: permission may be granted later
            engineReady = true
        }
        switch purpose {
        case .command:
            guard let t = await target(id) else { return "Session not found" }
            guard t.state != .ended else { return "This session has ended" }
            guard let pane = t.pane else { return "Open with cb for voice" }
            return await typer.verify(pane)
        case .other(let q):
            guard case .question(let options, _)? = await requests.shownShape(id: id), options.indices.contains(q) else {
                return "The question is no longer on the board"
            }
            return nil
        case .denyReason:
            guard case .permission? = await requests.shownShape(id: id) else { return "The request is no longer on the board" }
            return nil
        }
    }

    private func partial(_ voice: UInt32, _ text: String) async {
        guard var c = capture, c.voice == voice, !c.stopped else { return }
        let now = clock()
        guard text != c.lastPartial, now - c.lastPartialAt >= Self.partialInterval else { return }
        c.lastPartial = text
        c.lastPartialAt = now
        capture = c
        await post(voice, .partial(text))
    }

    private func stop(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.stopped else { return }
        c.stopped = true
        capture = c
        if c.stream != nil { await complete(voice) }   // else start() completes once the engine is ready
    }

    private func complete(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.finishing, let stream = c.stream else { return }
        c.finishing = true
        capture = c
        let raw = await stream.finish()
        guard capture?.voice == voice else { return }   // cancelled or replaced while finishing
        let text = VoiceText.forTyping(raw)
        capture?.final = text
        log("voice \(voice): final transcript, \(text.utf8.count) bytes")
        await post(voice, .final(text))
    }

    private func cancel(_ voice: UInt32) async {
        guard let c = capture, c.voice == voice, !c.sending else { return }
        capture = nil
        await c.stream?.cancel()
    }

    private func send(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.sending, let text = c.final else { return }   // no final yet: ignored
        guard !text.isEmpty else {
            await fail(voice, "Nothing to send")
            return
        }
        c.sending = true
        capture = c
        let result = await deliver(voice, text, c.purpose, c.target)
        if capture?.voice == voice { capture = nil }
        if let result { await post(voice, result) }
    }

    /// nil: the result already went to the board (deny with reason: before the next request is shown)
    private func deliver(_ voice: UInt32, _ text: String, _ purpose: VoicePurpose, _ id: UInt32) async -> VoiceUpdate? {
        switch purpose {
        case .command:
            guard let t = await target(id) else { return .error("Session not found — nothing sent") }
            // A terminal prompt (permission, question) would take the keystrokes as its answer
            guard t.state != .needsYou else { return .error("Claude is waiting for an answer in the terminal — nothing sent") }
            guard t.state != .ended else { return .error("This session has ended — nothing sent") }
            guard let pane = t.pane else { return .error("Open with cb for voice") }
            switch await typer.type(text, into: pane) {
            case .typed:
                log("voice \(voice): typed \(text.utf8.count) bytes into \(t.project) \(pane.pane)")
                return .done("Sent to \(t.project)")
            case .failed(let why):
                log("voice \(voice): not typed: \(why)")
                return .error(why)
            }
        case .other(let q):
            return await requests.setOther(id: id, question: q, text: text)
                ? .done("Added as your answer") : .error("The question is no longer on the board")
        case .denyReason:
            let notice = BoardMessage.voice(id: voice, .done("Denied with your reason"))
            return await requests.denyWithReason(id: id, message: text, notice: notice)
                ? nil : .error("The request is no longer on the board")
        }
    }

    private func expire(_ voice: UInt32) async {
        guard let c = capture, c.voice == voice, !c.sending else { return }
        await fail(voice, "Timed out — say it again")
    }

    private func fail(_ voice: UInt32, _ why: String) async {
        if let c = capture, c.voice == voice {
            capture = nil
            await c.stream?.cancel()
        }
        log("voice \(voice): \(why)")
        await post(voice, .error(why))
    }
}
