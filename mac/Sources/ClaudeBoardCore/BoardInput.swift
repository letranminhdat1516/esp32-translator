import Foundation

public enum BoardChoice: UInt8, Sendable { case allow = 1, deny = 2, alwaysAllow = 3 }

/// What the board shows, as it reports it: session traffic flows only for .claude and .picker.
public enum BoardMode: UInt8, Sendable { case other = 0, claude = 1, picker = 2 }

/// What a voice capture is for. Wire: purpose byte, low nibble 0 / 1 / 2, high nibble the question index (Other only).
public enum VoicePurpose: Equatable, Sendable {
    /// Typed into the session's tmux pane; target = session handle
    case command
    /// The spoken "Other" answer to question `question` of the AskUserQuestion on the board; target = request id
    case other(question: Int)
    /// Deny the permission request on the board with the spoken reason; target = request id
    case denyReason
}

/// Board → Mac on the answer characteristic. Request answers carry the request id (never 0); id 0 marks
/// board events; voice inputs carry the voice id (never 0).
///   [id u32 LE][1|2|3]                      allow / deny / always allow
///   [id u32 LE][0x10][n u8][mask × n]       question answers, bit i of mask q = option i, bit 7 = Other text
///   [0 u32][0x20][mode u8]                  board mode
///   [0 u32][0x21][handle u32 LE]            focus this session
///   [voice u32][0x30][purpose u8][target u32 LE]   voice capture starts
///   [voice u32][0x31] / [0x32] / [0x33]     audio complete / cancel / send the final transcript
public enum BoardInput: Equatable, Sendable {
    case choice(id: UInt32, BoardChoice)
    case answers(id: UInt32, masks: [UInt8])
    case mode(BoardMode)
    case focus(handle: UInt32)
    case voiceStart(voice: UInt32, purpose: VoicePurpose, target: UInt32)
    case voiceStop(voice: UInt32)
    case voiceCancel(voice: UInt32)
    case voiceSend(voice: UInt32)

    public static func decode(_ d: Data) -> BoardInput? {
        let b = [UInt8](d)
        guard b.count >= 5 else { return nil }
        let id = le32(b, 0)
        switch (id == 0, b[4]) {
        case (false, 1...3):
            guard b.count == 5, let c = BoardChoice(rawValue: b[4]) else { return nil }
            return .choice(id: id, c)
        case (false, 0x10):
            guard b.count >= 6 else { return nil }
            let n = Int(b[5])
            guard (1...AskQuestion.maxQuestions).contains(n), b.count == 6 + n else { return nil }
            return .answers(id: id, masks: Array(b[6...]))
        case (true, 0x20):
            guard b.count == 6, let m = BoardMode(rawValue: b[5]) else { return nil }
            return .mode(m)
        case (true, 0x21):
            guard b.count == 9 else { return nil }
            let h = le32(b, 5)
            return h == 0 ? nil : .focus(handle: h)
        case (false, 0x30):
            guard b.count == 10 else { return nil }
            let target = le32(b, 6)
            guard target != 0, let purpose = voicePurpose(b[5]) else { return nil }
            return .voiceStart(voice: id, purpose: purpose, target: target)
        case (false, 0x31):
            return b.count == 5 ? .voiceStop(voice: id) : nil
        case (false, 0x32):
            return b.count == 5 ? .voiceCancel(voice: id) : nil
        case (false, 0x33):
            return b.count == 5 ? .voiceSend(voice: id) : nil
        default:
            return nil
        }
    }

    private static func voicePurpose(_ byte: UInt8) -> VoicePurpose? {
        let question = Int(byte >> 4)
        switch byte & 0x0f {
        case 0: return question == 0 ? .command : nil
        case 1: return question < AskQuestion.maxQuestions ? .other(question: question) : nil
        case 2: return question == 0 ? .denyReason : nil
        default: return nil
        }
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
