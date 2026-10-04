import Foundation
import Testing
@testable import ClaudeRelay

@Test func chunksCarryFirstAndLastFlags() {
    let data = Data((0..<25).map { UInt8($0) })
    let c = BLEFraming.chunks(data, maxChunk: 11)          // 10 payload bytes per chunk
    #expect(c.count == 3)
    #expect(c.map { $0.first! } == [0x01, 0x00, 0x02])
    #expect(c.reduce(Data()) { $0 + $1.dropFirst() } == data)
    #expect(BLEFraming.chunks(Data([1]), maxChunk: 20) == [Data([0x03, 1])])
}

@Test func helloVectors() {
    #expect(BoardHello.mac == Data([0x09, 0, 0, 0, 0, 0x6d, 0x61, 0x63]))
    #expect(BoardHello.relay == Data([0x09, 0, 0, 0, 0, 0x72, 0x65, 0x6c, 0x61, 0x79]))
    #expect(BoardHello.kind == 9)
}
