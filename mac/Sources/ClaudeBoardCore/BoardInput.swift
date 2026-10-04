import Foundation

public enum BoardChoice: UInt8, Sendable { case allow = 1, deny = 2, alwaysAllow = 3 }

/// What the board shows, as it reports it: session traffic flows only for .claude and .picker.
public enum BoardMode: UInt8, Sendable { case other = 0, claude = 1, picker = 2 }

/// Board → Mac on the answer characteristic. Request answers carry the request id (never 0); id 0 marks
/// board events.
///   [id u32 LE][1|2|3]                      allow / deny / always allow
///   [id u32 LE][0x10][n u8][mask × n]       question answers, bit i of mask q = option i of question q
///   [0 u32][0x20][mode u8]                  board mode
///   [0 u32][0x21][handle u32 LE]            focus this session
public enum BoardInput: Equatable, Sendable {
    case choice(id: UInt32, BoardChoice)
    case answers(id: UInt32, masks: [UInt8])
    case mode(BoardMode)
    case focus(handle: UInt32)

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
        default:
            return nil
        }
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
