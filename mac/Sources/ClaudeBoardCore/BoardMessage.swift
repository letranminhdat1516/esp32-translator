import Foundation

public enum Decision: UInt8, Sendable { case allow = 1, deny = 2 }

public struct Answer: Equatable, Sendable {
    public let id: UInt32
    public let decision: Decision

    public init(id: UInt32, decision: Decision) { self.id = id; self.decision = decision }

    /// [id u32 LE][decision u8]
    public static func decode(_ d: Data) -> Answer? {
        let b = [UInt8](d)
        guard b.count == 5, let decision = Decision(rawValue: b[4]) else { return nil }
        let id = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return Answer(id: id, decision: decision)
    }
}

public enum BoardMessage: Equatable, Sendable {
    case permission(id: UInt32, project: String, tool: String, summary: String)
    case finished(id: UInt32, project: String, line: String)
    case cancel(id: UInt32)

    /// [kind u8][id u32 LE][UTF-8 text]; kind 0 permission, 1 finished, 2 cancel
    public func encode() -> Data {
        let (kind, id, text): (UInt8, UInt32, String) = switch self {
        case .permission(let id, let p, let t, let s): (0, id, "\(p)\n\(t)\n\(s)")
        case .finished(let id, let p, let l): (1, id, "\(p)\n\(l)")
        case .cancel(let id): (2, id, "")
        }
        var d = Data([kind, UInt8(id & 0xff), UInt8(id >> 8 & 0xff), UInt8(id >> 16 & 0xff), UInt8(id >> 24)])
        d.append(contentsOf: text.utf8)
        return d
    }

    /// Splits a message into BLE writes: [flags u8][payload], flags bit0 = first, bit1 = last
    public static func chunks(_ data: Data, maxChunk: Int) -> [Data] {
        let size = max(1, maxChunk - 1)
        var out: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }
            if end == data.count { flags |= 0x02 }
            out.append(Data([flags]) + data[data.startIndex + offset ..< data.startIndex + end])
            offset = end
        } while offset < data.count
        return out
    }
}
