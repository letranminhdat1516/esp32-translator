import ClaudeRelay
import Foundation
import Network

/// Relays the board's Claude messages to the paired Mac and back (RelayBridge decides; this performs).
/// The WebSocket is open only while the app is paired and the board's Claude service is connected (battery). Failed
/// connections retry with backoff (5 s doubling to 5 min) and once at each network change. No other polling: the
/// bridge's tick runs only during a board voice session (it ends a finished session whose transcript never came).
/// All state lives on `queue`.
final class ClaudeRelayService: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case notPaired, waitingForBoard, connecting, relayReady, failed(String)
    }

    var onStatus: (@Sendable (Status, String?) -> Void)?   // status, paired host
    /// The pairing could not be stored in the Keychain (it is used until the app quits)
    var onSaveFailed: (@Sendable () -> Void)?

    private let link: ESPLink
    private let queue = DispatchQueue(label: "relay.service")
    private var bridge = RelayBridge()
    private var pairing: RelayPairing?
    private var client: RelayClient?
    private var boardUp = false
    private var macUp = false
    private var lastError: String?
    private var retryDelay: TimeInterval = 5
    private var retryGeneration = 0
    private var lastPartial = Date.distantPast
    private let monitor = NWPathMonitor()
    private let voice = VoiceWorker()
    private var speechReady = false
    private var preparing = false
    /// Drives RelayBridge's tick (about once a second) while a board voice session is open
    private var ticker: DispatchSourceTimer?
    private var tickSession: UInt32?
    private var lastTick = DispatchTime.now()

    init(link: ESPLink) {
        self.link = link
        link.onClaudeReady = { [weak self] max in self?.queue.async { self?.boardReady(max) } }
        link.onClaudeSubscribed = { [weak self] on in self?.queue.async { self?.handle(.boardSubscribed(on)) } }
        link.onClaudeInput = { [weak self] d in self?.queue.async { self?.handle(.boardInput(d)) } }
        link.onClaudeVoice = { [weak self] p in self?.queue.async { self?.handle(.boardVoice(p)) } }
        link.onTranslatorActive = { [weak self] in self?.queue.async { self?.handle(.translatorActive) } }
        voice.onEvent = { [weak self] e in self?.queue.async { self?.voiceEvent(e) } }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            self?.queue.async { self?.retryNow() }
        }
        monitor.start(queue: queue)
        queue.async { [self] in
            pairing = RelayKeychain.load()
            publish()
        }
    }

    func pair(_ p: RelayPairing) {
        queue.async { [self] in
            if !RelayKeychain.save(p) { onSaveFailed?() }
            pairing = p
            prepareSpeech()   // only once a Mac is paired: may ask for Speech Recognition
            dropClient()
            retryDelay = 5
            lastError = nil
            connectIfNeeded()
            publish()
        }
    }

    func forget() {
        queue.async { [self] in
            RelayKeychain.forget()
            pairing = nil
            dropClient()
            lastError = nil
            publish()
        }
    }

    /// Checks (again) whether the board's voice can be transcribed here: the Vietnamese model may only be installed
    /// once the translator has run, so a failed check is repeated each time the board's Claude service comes up.
    /// Only while paired: it may ask for Speech Recognition, which an unpaired user should never see for the relay.
    private func prepareSpeech() {
        guard pairing != nil, !speechReady, !preparing else { return }
        preparing = true
        Task { [weak self, voice] in
            let why = await voice.prepare()
            self?.queue.async {
                guard let self else { return }
                self.preparing = false
                self.speechReady = why == nil
                if let why { Diag.log("relay: board voice not available: \(why)") }
                self.handle(.speech(why))
            }
        }
    }

    private func boardReady(_ max: Int?) {
        boardUp = max != nil
        handle(max.map { .boardUp(maxWrite: $0) } ?? .boardDown)
        if boardUp {
            connectIfNeeded()
            prepareSpeech()
        } else {
            dropClient()   // no board, no WebSocket
        }
        publish()
    }

    private func connectIfNeeded() {
        guard let pairing, boardUp, client == nil else { return }
        let c = RelayClient(pairing: pairing)
        c.onState = { [weak self, weak c] s in self?.queue.async { if let c { self?.clientState(s, c) } } }
        c.onFrame = { [weak self] f in self?.queue.async { self?.handle(.mac(f)) } }
        client = c
        c.connect()
    }

    private func dropClient() {
        retryGeneration += 1
        client?.disconnect()
        client = nil
        if macUp {
            macUp = false
            handle(.macDown)
        }
    }

    private func clientState(_ s: RelayClient.State, _ c: RelayClient) {
        guard c === client else { return }
        switch s {
        case .authenticated:
            macUp = true
            retryDelay = 5
            lastError = nil
            handle(.macUp)
        case .failed(let why):
            Diag.log("relay: \(why)")
            lastError = why
            client = nil
            if macUp {
                macUp = false
                handle(.macDown)
            }
            scheduleRetry()
        case .idle, .connecting:
            break
        }
        publish()
    }

    private func scheduleRetry() {
        retryGeneration += 1
        let gen = retryGeneration
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.retryGeneration else { return }
            self.connectIfNeeded()
        }
    }

    private func retryNow() {
        guard client == nil, pairing != nil, boardUp else { return }
        retryGeneration += 1
        connectIfNeeded()
    }

    private func handle(_ e: RelayBridge.Event) {
        for action in bridge.handle(e) { perform(action) }
        publish()
    }

    private func perform(_ a: RelayBridge.Action) {
        switch a {
        case .subscribeBoard(let on): link.setClaudeSubscribed(on)
        case .subscribeVoice(let on): link.setClaudeVoice(on)
        case .writeBoard(let chunk): link.writeClaude(chunk)
        case .toMac(let f):
            client?.send(f)
            if case .voiceFailed(let s, _) = f { stopTicking(s) }   // the bridge ended the session
        case .transcribeBegin(let s):
            lastPartial = .distantPast
            voice.send(.begin(s))
            startTicking(s)
        case .transcribeFeed(let p): voice.send(.feed(p))
        case .transcribeFinish(let s): voice.send(.finish(s))
        case .transcribeCancel:
            voice.send(.cancel)
            stopTicking(nil)
        }
    }

    private func voiceEvent(_ e: VoiceWorker.Event) {
        switch e {
        case .partial(let s, let text):
            let now = Date()
            guard now.timeIntervalSince(lastPartial) >= 0.25 else { return }   // at most 4 partials a second
            lastPartial = now
            handle(.transcript(s, final: false, text))
        case .final(let s, let text):
            handle(.transcript(s, final: true, text))
            stopTicking(s)
        case .failed(let s, let why):
            Diag.log("relay: board voice \(s): \(why)")
            handle(.transcriptFailed(s, why))
            stopTicking(s)
        }
    }

    private func startTicking(_ session: UInt32) {
        tickSession = session
        guard ticker == nil else { return }
        lastTick = .now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            let dt = Double(now.uptimeNanoseconds &- self.lastTick.uptimeNanoseconds) / 1e9
            self.lastTick = now
            self.handle(.tick(dt))
        }
        t.resume()
        ticker = t
    }

    /// Stops the tick when `session` (nil: whichever) is the one it runs for (a late event of an older session
    /// must not stop a newer one's)
    private func stopTicking(_ session: UInt32?) {
        guard session == nil || session == tickSession else { return }
        tickSession = nil
        ticker?.cancel()
        ticker = nil
    }

    private func publish() {
        let status: Status =
            pairing == nil ? .notPaired
            : !boardUp ? .waitingForBoard
            : macUp && bridge.linked ? .relayReady
            : lastError.map(Status.failed) ?? .connecting
        onStatus?(status, pairing?.host)
    }
}
