import Foundation

/// The board's voice audio (IMA ADPCM packets [seq u16][predictor i16][index u8][data]) from the current
/// capture's first packet (seq 0) until the Mac's voiceBegin. Only the latest capture is kept.
public struct VoiceAudioBuffer: Sendable {
    /// 32 s of 20 ms packets (a board capture stops at 30 s). When full, the oldest packets are kept and newer
    /// ones dropped: a transcript of the start of an utterance beats one with a hole in the middle.
    public static let maxPackets = 1600
    public private(set) var packets: [Data] = []

    public init() {}

    public static func seq(_ packet: Data) -> UInt16? {
        guard packet.count >= 5 else { return nil }
        return UInt16(packet[packet.startIndex]) | UInt16(packet[packet.startIndex + 1]) << 8
    }

    public mutating func append(_ packet: Data) {
        guard let s = Self.seq(packet) else { return }
        if s == 0 { packets = [] }
        else if packets.isEmpty { return }   // a capture's tail (its start was missed or already fed) starts nothing
        if packets.count < Self.maxPackets { packets.append(packet) }
    }

    public mutating func take() -> [Data] {
        defer { packets = [] }
        return packets
    }
}

/// The iPhone relay as a pure state machine: events from the Mac connection, the board's Claude service and the
/// phone's transcriber in, actions out. It never reads a board message. Board bytes go through unchanged (toBoard
/// is chunked like the Mac does, fromBoard is forwarded as notified). Its own words are the link hello, the board
/// link and voice status frames, and transcripts. The board subscription exists only while the Mac is reachable,
/// so the board falls back to "Mac not connected" instead of a relay that leads nowhere.
public struct RelayBridge: Sendable {
    public enum Event: Equatable, Sendable {
        case macUp, macDown
        /// The board's Claude characteristics were found (write size for chunks) / the board link went away
        case boardUp(maxWrite: Int), boardDown
        /// The answer subscription was confirmed (true) or ended. Confirmed again while linked: the hello is repeated.
        case boardSubscribed(Bool)
        /// The app wrote to the board's translator service after a silence (or for the first time on this link): the
        /// board may have just given this link the translator role, the only one it takes the relay hello on
        case translatorActive
        case boardInput(Data)
        case boardVoice(Data)
        case mac(RelayFrame)
        /// nil: the phone can transcribe the board's voice; else why not
        case speech(String?)
        case transcript(UInt32, final: Bool, String)
        case transcriptFailed(UInt32, String)
        /// Time passed (seconds since the previous tick). The caller must drive this (about once a second) so a
        /// finished session that never gets a final transcript ends after `finishTimeout`.
        case tick(TimeInterval)
    }

    public enum Action: Equatable, Sendable {
        case subscribeBoard(Bool)
        case subscribeVoice(Bool)
        /// One chunk to the request characteristic, written with response, in order
        case writeBoard(Data)
        case toMac(RelayFrame)
        case transcribeBegin(UInt32)
        case transcribeFeed(Data)
        case transcribeFinish(UInt32)
        case transcribeCancel
    }

    /// How long after voiceFinish the transcriber has to deliver a final transcript (matches the Mac's RelayVoice)
    public static let finishTimeout: TimeInterval = 15
    static let finishTimedOut = "The iPhone did not finish the transcript in time"

    private var macUp = false
    private var maxWrite: Int?
    private var wantSubscribed = false
    private var subscribed = false
    private var speech: String? = "Speech recognition is not ready on the iPhone"
    private var session: UInt32?
    private var sessionFed = 0
    private var sessionAudioOpen = false
    /// Seconds since voiceFinish, while waiting for the final transcript
    private var finishWaited: TimeInterval?
    /// The board started a new capture during the session: the buffered audio is that capture's, not stale
    private var sessionRestarted = false
    private var audio = VoiceAudioBuffer()

    public init() {}

    /// The phone holds the board's relay role and the Mac is reachable
    public var linked: Bool { macUp && maxWrite != nil && subscribed }

    public mutating func handle(_ e: Event) -> [Action] {
        var out: [Action] = []
        let wasLinked = linked
        switch e {
        case .macUp: macUp = true
        case .macDown:
            macUp = false
            audio = VoiceAudioBuffer()
        case .boardUp(let m): maxWrite = max(20, m)
        case .boardDown:
            audio = VoiceAudioBuffer()
            maxWrite = nil
            wantSubscribed = false
            subscribed = false
        case .boardSubscribed(let on):
            subscribed = on && wantSubscribed
            if wasLinked && linked { out += hello() }
        case .translatorActive:
            if linked { out += hello() }
        case .boardInput(let d):
            if linked, (5...RelayFrame.maxBoardInput).contains(d.count) { out.append(.toMac(.fromBoard(d))) }
        case .boardVoice(let p): voice(p, &out)
        case .mac(let f): mac(f, &out)
        case .speech(let why):
            speech = why
            if let why, let s = session {
                out += [.transcribeCancel, .toMac(.voiceFailed(s, Self.reason(why)))]
                endSession()
            }
            if linked { out += [.toMac(.voiceStatus(why.map(Self.reason))), .subscribeVoice(why == nil)] }
        case .transcript(let s, let final, let text):
            guard s == session else { break }
            out.append(.toMac(.transcript(s, final: final, RelayFrame.fit(text, maxBytes: RelayFrame.maxText))))
            if final { endSession() }
        case .transcriptFailed(let s, let why):
            guard s == session else { break }
            out.append(.toMac(.voiceFailed(s, Self.reason(why))))
            endSession()
        case .tick(let dt):
            guard let s = session, let waited = finishWaited else { break }
            let total = waited + max(0, dt)
            finishWaited = total
            if total >= Self.finishTimeout {
                out += [.transcribeCancel, .toMac(.voiceFailed(s, Self.finishTimedOut))]
                endSession()
            }
        }
        // The board subscription follows "Mac reachable and board present"
        let want = macUp && maxWrite != nil
        if maxWrite != nil && want != wantSubscribed {
            wantSubscribed = want
            if !want { subscribed = false }
            out.append(.subscribeBoard(want))
            if !want { out.append(.subscribeVoice(false)) }
        }
        if !wasLinked && linked {
            out += hello()
            out += [.toMac(.boardLink(true)), .toMac(.voiceStatus(speech.map(Self.reason)))]
            if speech == nil { out.append(.subscribeVoice(true)) }
        } else if wasLinked && !linked {
            if macUp { out.append(.toMac(.boardLink(false))) }
            if session != nil { out.append(.transcribeCancel) }
            endSession()
            audio = VoiceAudioBuffer()
        }
        return out
    }

    /// The relay hello, whole (it is never interleaved with another message's chunks: one handle() call emits it)
    private func hello() -> [Action] {
        guard let m = maxWrite else { return [] }
        return BLEFraming.chunks(BoardHello.relay, maxChunk: m).map(Action.writeBoard)
    }

    private mutating func mac(_ f: RelayFrame, _ out: inout [Action]) {
        switch f {
        case .toBoard(let d):
            guard linked, let m = maxWrite else { return }
            out += BLEFraming.chunks(d, maxChunk: m).map(Action.writeBoard)
        case .voiceBegin(let s):
            guard linked, speech == nil else {
                audio = VoiceAudioBuffer()
                out.append(.toMac(.voiceFailed(s, Self.reason(speech ?? "The board is not connected to the iPhone"))))
                return
            }
            if session != nil { out.append(.transcribeCancel) }
            session = s
            sessionFed = 0
            sessionAudioOpen = true
            sessionRestarted = false
            finishWaited = nil
            out.append(.transcribeBegin(s))
            for p in audio.take() {
                out.append(.transcribeFeed(p))
                sessionFed += 1
            }
        case .voiceFinish(let s):
            guard s == session else { return }
            sessionAudioOpen = false
            finishWaited = 0
            out.append(.transcribeFinish(s))
        case .voiceCancel(let s):
            guard s == session else { return }
            out.append(.transcribeCancel)
            endSession()
        default:
            break   // handshake frames stay in RelayClient
        }
    }

    private mutating func voice(_ p: Data, _ out: inout [Action]) {
        guard let seq = VoiceAudioBuffer.seq(p) else { return }
        let restarted = seq == 0 && sessionFed > 0
        if session != nil && sessionAudioOpen && !restarted {
            out.append(.transcribeFeed(p))
            sessionFed += 1
            return
        }
        if restarted {
            sessionAudioOpen = false
            sessionRestarted = true
        }   // a new capture: the open session gets no more audio
        audio.append(p)
    }

    /// Ends the session and drops its leftover audio. Audio of a capture the board restarted during the session
    /// (seq 0 again) is kept: the Mac's next voiceBegin is for that capture.
    private mutating func endSession() {
        if !sessionRestarted { audio = VoiceAudioBuffer() }
        session = nil
        sessionFed = 0
        sessionAudioOpen = false
        sessionRestarted = false
        finishWaited = nil
    }

    private static func reason(_ s: String) -> String {
        let r = RelayFrame.fit(s, maxBytes: RelayFrame.maxReason)
        return r.isEmpty ? "Speech recognition failed on the iPhone" : r
    }
}
