// The board's side of Them → You, ported from firmware/main (the app has no encoder): the translator VAD of
// audio_in.c (translator_step) and the IMA ADPCM encoder of adpcm.c, packetized as the firmware sends it:
// [seq u16][predictor i16][index u8][data, low nibble first], 320 samples (20 ms) per packet.
import Foundation

struct ADPCMEncoder {
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
    private var predictor = 0
    private var index = 0
    private var seq: UInt16 = 0

    private mutating func encode(_ sample: Int16) -> UInt8 {
        var step = Self.stepTable[index]
        var diff = Int(sample) - predictor
        var code: UInt8 = 0
        if diff < 0 { code = 8; diff = -diff }
        var delta = step >> 3
        if diff >= step { code |= 4; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 2; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 1; delta += step }
        predictor = min(32767, max(-32768, predictor + ((code & 8) != 0 ? -delta : delta)))
        index = min(88, max(0, index + Self.indexTable[Int(code)]))
        return code
    }

    /// One BLE packet for an even number of samples (the header carries the state before them)
    mutating func packet(_ samples: ArraySlice<Int16>) -> Data {
        var out = [UInt8](repeating: 0, count: 5 + samples.count / 2)
        out[0] = UInt8(seq & 0xff); out[1] = UInt8(seq >> 8)
        let p = UInt16(bitPattern: Int16(predictor))
        out[2] = UInt8(p & 0xff); out[3] = UInt8(p >> 8)
        out[4] = UInt8(index)
        seq &+= 1
        var i = samples.startIndex, o = 5
        while i + 1 < samples.endIndex {
            let lo = encode(samples[i]), hi = encode(samples[i + 1])
            out[o] = lo | (hi << 4)
            i += 2; o += 1
        }
        return Data(out)
    }
}

/// translator_step of firmware/main/audio_in.c: energy VAD with 300 ms pre-roll and 800 ms hangover. Returns
/// the 20 ms frames to send for this input frame (the pre-roll burst when speech starts).
struct BoardVAD {
    static let prerollFrames = 15, startFrames = 2
    /// VAD_HANGOVER_FRAMES (40 = 800 ms); BOARD_HANGOVER_MS overrides it for experiments
    let hangoverFrames = env["BOARD_HANGOVER_MS"].flatMap(Int.init).map { max(1, $0 / 20) } ?? 40
    static let marginDB: Float = 10, minDB: Float = -58, floorRiseDB: Float = 0.01
    private(set) var floorDB: Float = -60
    private var above = 0
    private var hangover = 0
    private(set) var speaking = false
    private var preroll: [[Int16]] = []

    mutating func step(_ frame: [Int16]) -> [[Int16]] {
        var e = 0.0
        for s in frame { e += Double(s) * Double(s) }
        let db = Float(10 * log10(e / Double(frame.count) / (32768.0 * 32768.0) + 1e-10))
        if db < floorDB { floorDB = db } else { floorDB += Self.floorRiseDB }
        let voiced = db > floorDB + Self.marginDB && db > Self.minDB
        above = voiced ? above + 1 : 0
        var out: [[Int16]] = []
        if !speaking && above >= Self.startFrames {
            speaking = true
            out = preroll
            preroll.removeAll()
        }
        if speaking {
            out.append(frame)
            if voiced {
                hangover = hangoverFrames
            } else {
                hangover -= 1
                if hangover <= 0 { speaking = false }
            }
        } else {
            preroll.append(frame)
            if preroll.count > Self.prerollFrames { preroll.removeFirst() }
        }
        return out
    }
}
