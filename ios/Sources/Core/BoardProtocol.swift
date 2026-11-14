import Foundation

// The subtitle board's BLE protocol, byte-compatible with the firmware (firmware/main/ble_link.c).

/// First byte after the flags of a text chunk: what the board does with it.
enum TextKind: UInt8, CaseIterable, Sendable {
    case subtitle = 0, status = 1, time = 2
    /// The other language's label on the status line (≤ `BoardProtocol.maxLabelBytes`). Only for boards that have
    /// the `…0005` board-info characteristic: older firmware shows unknown kinds as subtitles.
    case label = 3
}

enum BoardProtocol {
    static let serviceUUID = "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A"
    /// Notify: audio packets from the board mic.
    static let audioUUID = "A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A"
    /// Write: text chunks `[flags][kind][payload]`.
    static let textUUID = "A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A"
    /// Write: mic on/off and keepalive; notify: mic state changes.
    static let controlUUID = "A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A"
    /// Read: `[version u8][fontSets u32 LE]`. Absent on older firmware.
    static let infoUUID = "A7C00005-3B2F-4C1E-9D8A-5F6E7D8C9B0A"

    /// The round screen shows about 5 lines, so only this many bytes are sent.
    static let maxTextBytes = 150
    /// Longest label the board accepts (UTF-8 bytes).
    static let maxLabelBytes = 32

    /// Splits `text` into the chunks written to the text characteristic, like `ESPLink.send`: the tail of the text
    /// within `maxTextBytes`; `maxWrite` is the peripheral's maximum write-without-response length and the payload per
    /// chunk is `max(20, maxWrite) - 2`. Flags: bit0 first chunk, bit1 last chunk. Always at least one chunk.
    static func frameText(_ text: String, kind: TextKind, maxWrite: Int) -> [Data] {
        let payload = Array(tail(text).utf8)
        let size = max(20, maxWrite) - 2
        var chunks: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, payload.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }
            if end == payload.count { flags |= 0x02 }
            chunks.append(Data([flags, kind.rawValue] + payload[offset..<end]))
            offset = end
        } while offset < payload.count
        return chunks
    }

    /// Payload of the clock message: `"<unix seconds> <UTC offset minutes>"`.
    static func timeText(at date: Date = Date(), in timeZone: TimeZone = .current) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let offset = timeZone.secondsFromGMT(for: date) / 60
        return "\(seconds) \(offset)"
    }

    /// The clock message as one chunk (flags 0x03, kind 2), like `ESPLink.timePayload`.
    static func timeFrame(at date: Date = Date(), in timeZone: TimeZone = .current) -> Data {
        Data([0x03, TextKind.time.rawValue]) + Data(timeText(at: date, in: timeZone).utf8)
    }

    /// Cuts `label` to at most `maxLabelBytes` UTF-8 bytes at a character boundary, without an ellipsis.
    static func labelText(_ label: String) -> String {
        var bytes = 0
        var out = ""
        for ch in label {
            let n = ch.utf8.count
            if bytes + n > maxLabelBytes { break }
            bytes += n
            out.append(ch)
        }
        return out
    }

    /// Parses the board-info characteristic; nil when shorter than 5 bytes.
    static func parseBoardInfo(_ data: Data) -> BoardInfo? {
        let b = Array(data)
        guard b.count >= 5 else { return nil }
        let sets = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        return BoardInfo(protocolVersion: Int(b[0]), fontSets: FontSets(rawValue: sets))
    }

    /// Mirrors `ESPLink.tail(of:maxBytes:)`: keeps the tail within `maxTextBytes` without splitting a character, then
    /// drops the partial word up to the first space and prefixes "…".
    private static func tail(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var result = Substring(text)
        while result.utf8.count > maxTextBytes { result = result.dropFirst() }
        if let space = result.firstIndex(of: " ") { result = result[result.index(after: space)...] }
        return "…" + result
    }
}
