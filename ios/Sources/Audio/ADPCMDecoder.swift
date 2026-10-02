import Foundation

/// Decodes IMA ADPCM packets from the board: [seq u16][predictor i16][index u8][data, low nibble first].
/// Every packet carries its own state, so a lost packet only needs matching silence inserted.
struct ADPCMDecoder {
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
    private static let maxGapPackets = 10

    private var lastSeq: UInt16?

    mutating func decode(_ packet: Data) -> [Int16] {
        guard packet.count > 5 else { return [] }
        let bytes = [UInt8](packet)
        let seq = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var predictor = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
        var index = Int(bytes[4])
        let samplesPerPacket = (bytes.count - 5) * 2

        var out: [Int16] = []
        if let lastSeq {
            let gap = Int(seq &- lastSeq) - 1
            if gap > 0 && gap <= Self.maxGapPackets {
                out.append(contentsOf: repeatElement(0, count: gap * samplesPerPacket))
            }
        }
        lastSeq = seq
        out.reserveCapacity(out.count + samplesPerPacket)

        for byte in bytes[5...] {
            for code in [Int(byte & 0x0f), Int(byte >> 4)] {
                let step = Self.stepTable[index]
                var delta = step >> 3
                if code & 4 != 0 { delta += step }
                if code & 2 != 0 { delta += step >> 1 }
                if code & 1 != 0 { delta += step >> 2 }
                predictor += (code & 8 != 0) ? -delta : delta
                predictor = min(32767, max(-32768, predictor))
                index = min(88, max(0, index + Self.indexTable[code]))
                out.append(Int16(predictor))
            }
        }
        return out
    }

    mutating func reset() { lastSeq = nil }
}
