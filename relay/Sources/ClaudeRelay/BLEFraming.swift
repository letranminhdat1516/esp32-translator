import Foundation

/// The board's request characteristic takes one message as BLE writes [flags u8][payload], flags bit0 = first,
/// bit1 = last. The Mac (direct) and the iPhone (relay) both chunk with this, to their link's write size.
public enum BLEFraming {
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

/// Link hello (message kind 9, id 0), written once after the answer subscription is confirmed. The board gives a
/// connection a Claude role only from this: "mac" (the daemon, direct BLE) or "relay" (the iPhone app).
public enum BoardHello {
    public static let kind: UInt8 = 9
    public static let mac = Data([kind, 0, 0, 0, 0]) + Data("mac".utf8)
    public static let relay = Data([kind, 0, 0, 0, 0]) + Data("relay".utf8)
}
