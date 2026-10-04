import Foundation

/// One WebSocket binary message between the Mac daemon and the iPhone relay. The board's own bytes travel
/// unchanged inside toBoard / fromBoard; everything else is the relay's own small vocabulary (README, "Relay
/// protocol"). Integers are little-endian.
public enum RelayFrame: Equatable, Sendable {
    /// Mac → phone: one encoded board message ([kind][id u32][text]); the phone chunks it to the board
    case toBoard(Data)
    /// Phone → Mac: one answer-characteristic notification, exactly as the board sent it
    case fromBoard(Data)
    /// Phone → Mac: the phone holds (or lost) the board's relay role
    case boardLink(Bool)
    /// Phone → Mac: nil = the phone can transcribe board voice; else why not (shown on the board)
    case voiceStatus(String?)
    /// Mac → phone: transcribe the board's current capture as session n / end it and send the final / drop it
    case voiceBegin(UInt32)
    case voiceFinish(UInt32)
    case voiceCancel(UInt32)
    /// Phone → Mac: transcript of session n (partial, or the final one after voiceFinish)
    case transcript(UInt32, final: Bool, String)
    /// Phone → Mac: session n could not be transcribed
    case voiceFailed(UInt32, String)
    /// Handshake: Mac challenge [version][nonceS 32], phone auth [nonceC 32][proof 32], Mac welcome [proof 32]
    case challenge(Data)
    case auth(nonce: Data, proof: Data)
    case welcome(Data)

    public enum Sender: Equatable, Sendable { case mac, phone }

    public static let version: UInt8 = 1
    /// 5-byte header + the board's CLAUDE_TEXT_MAX (400)
    public static let maxBoardMessage = 405
    /// The board's CLAUDE_INPUT_MAX
    public static let maxBoardInput = 10
    public static let maxText = 1000
    public static let maxReason = 200
    public static let maxFrame = 2048

    public var sender: Sender {
        switch self {
        case .toBoard, .voiceBegin, .voiceFinish, .voiceCancel, .challenge, .welcome: .mac
        case .fromBoard, .boardLink, .voiceStatus, .transcript, .voiceFailed, .auth: .phone
        }
    }

    public func encode() -> Data {
        switch self {
        case .toBoard(let d): return Data([0x01]) + d
        case .fromBoard(let d): return Data([0x02]) + d
        case .boardLink(let up): return Data([0x03, up ? 1 : 0])
        case .voiceStatus(let why): return why.map { Data([0x04, 1]) + Data($0.utf8) } ?? Data([0x04, 0])
        case .voiceBegin(let s): return Data([0x10]) + Self.le32(s)
        case .voiceFinish(let s): return Data([0x11]) + Self.le32(s)
        case .voiceCancel(let s): return Data([0x12]) + Self.le32(s)
        case .transcript(let s, let final, let text): return Data([0x13]) + Self.le32(s) + Data([final ? 1 : 0]) + Data(text.utf8)
        case .voiceFailed(let s, let why): return Data([0x14]) + Self.le32(s) + Data(why.utf8)
        case .challenge(let body): return Data([0x20]) + body
        case .auth(let nonce, let proof): return Data([0x21]) + nonce + proof
        case .welcome(let proof): return Data([0x22]) + proof
        }
    }

    /// encode(), but only for a frame `sender` may send and the peer's decode accepts (a frame it would refuse
    /// closes the connection): nil for anything else, which the sockets then drop
    public func wire(from sender: Sender) -> Data? {
        let data = encode()
        return Self.decode(data, from: sender) == self ? data : nil
    }

    /// nil: malformed, unknown, or not a frame `sender` may send (the connection is then closed)
    public static func decode(_ data: Data, from sender: Sender) -> RelayFrame? {
        guard data.count <= maxFrame else { return nil }      // before copying: the peer controls data.count
        let all = [UInt8](data)
        guard let type = all.first else { return nil }
        let b = Array(all.dropFirst())
        let frame: RelayFrame?
        switch type {
        case 0x01: frame = (5...maxBoardMessage).contains(b.count) ? .toBoard(Data(b)) : nil
        case 0x02: frame = (5...maxBoardInput).contains(b.count) ? .fromBoard(Data(b)) : nil
        case 0x03: frame = b.count == 1 && b[0] <= 1 ? .boardLink(b[0] == 1) : nil
        case 0x04:
            if b == [0] { frame = .voiceStatus(nil) }
            else if b.first == 1, let why = text(b.dropFirst(), 1...maxReason) { frame = .voiceStatus(why) }
            else { frame = nil }
        case 0x10, 0x11, 0x12:
            guard b.count == 4, let s = session(b) else { return nil }
            frame = type == 0x10 ? .voiceBegin(s) : type == 0x11 ? .voiceFinish(s) : .voiceCancel(s)
        case 0x13:
            guard b.count >= 5, let s = session(b), b[4] <= 1, let t = text(b.dropFirst(5), 0...maxText) else { return nil }
            frame = .transcript(s, final: b[4] == 1, t)
        case 0x14:
            guard b.count >= 4, let s = session(b), let why = text(b.dropFirst(4), 1...maxReason) else { return nil }
            frame = .voiceFailed(s, why)
        case 0x20: frame = b.count == 33 && b[0] == version ? .challenge(Data(b)) : nil
        case 0x21: frame = b.count == 64 ? .auth(nonce: Data(b[0..<32]), proof: Data(b[32..<64])) : nil
        case 0x22: frame = b.count == 32 ? .welcome(Data(b)) : nil
        default: frame = nil
        }
        guard let frame, frame.sender == sender else { return nil }
        return frame
    }

    /// The longest prefix of `s` within `maxBytes` UTF-8 bytes, cut at a Character boundary
    public static func fit(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]) }

    private static func session(_ b: [UInt8]) -> UInt32? {
        let s = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return s == 0 ? nil : s
    }

    private static func text(_ bytes: ArraySlice<UInt8>, _ range: ClosedRange<Int>) -> String? {
        guard range.contains(bytes.count) else { return nil }
        return String(bytes: Array(bytes), encoding: .utf8)
    }
}
