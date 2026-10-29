import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/board/protocol_test.dart, driven by shared/fixtures/protocol.json, plus Swift-only edge cases.

private func hex(_ d: Data) -> String {
    d.map { String(format: "%02x", $0) }.joined()
}

private func bytes(_ hex: String) -> Data {
    var out = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private let fixture = Fixtures.load("protocol")

@Suite struct BoardProtocolFixtureTests {
    @Test func uuids() {
        let u = fixture["uuids"] as! [String: String]
        #expect(BoardProtocol.serviceUUID == u["service"])
        #expect(BoardProtocol.audioUUID == u["audio"])
        #expect(BoardProtocol.textUUID == u["text"])
        #expect(BoardProtocol.controlUUID == u["control"])
        #expect(BoardProtocol.infoUUID == u["info"])
    }

    @Test func textKindsAndLimits() {
        let kinds = fixture["textKinds"] as! [String: Int]
        #expect(kinds.count == TextKind.allCases.count)
        for kind in TextKind.allCases {
            #expect(kinds["\(kind)"] == Int(kind.rawValue), "\(kind)")
        }
        #expect(BoardProtocol.maxTextBytes == fixture["maxTextBytes"] as! Int)
        #expect(BoardProtocol.maxLabelBytes == fixture["maxLabelBytes"] as! Int)
    }

    @Test(arguments: Fixtures.cases(in: fixture, "frameText", fixture: "protocol"))
    func frameText(_ c: FixtureCase) throws {
        let j = c.json
        let kind = try #require(TextKind.allCases.first { "\($0)" == j["kind"] as! String })
        let chunks = BoardProtocol.frameText(j["text"] as! String, kind: kind, maxWrite: j["maxWrite"] as! Int)
        #expect(chunks.map(hex) == j["expected"] as! [String])
    }

    @Test(arguments: Fixtures.cases(in: fixture, "labelText", fixture: "protocol"))
    func labelText(_ c: FixtureCase) {
        let j = c.json
        #expect(BoardProtocol.labelText(j["input"] as! String) == j["expected"] as! String)
    }

    @Test(arguments: Fixtures.cases(in: fixture, "boardInfo", fixture: "protocol"))
    func boardInfo(_ c: FixtureCase) {
        let j = c.json
        let info = BoardProtocol.parseBoardInfo(bytes(j["hex"] as! String))
        if let e = j["expected"] as? [String: Any] {
            #expect(info == BoardInfo(protocolVersion: e["protocolVersion"] as! Int,
                                      fontSets: FontSets(rawValue: UInt32(e["fontSets"] as! Int))))
        } else {
            #expect(info == nil)
        }
    }

    @Test(arguments: Fixtures.cases(in: fixture, "timeText", fixture: "protocol"))
    func timeText(_ c: FixtureCase) throws {
        let j = c.json
        let date = Date(timeIntervalSince1970: Double(j["epochMs"] as! Int) / 1000)
        let zone = try #require(TimeZone(secondsFromGMT: (j["utcOffsetMinutes"] as! Int) * 60))
        #expect(BoardProtocol.timeText(at: date, in: zone) == j["expected"] as! String)
    }
}

@Suite struct BoardProtocolTests {
    @Test func longTextWithoutSpacesKeepsTheByteTail() throws {
        let text = String(repeating: "ạ", count: 100)  // 3 bytes each
        let f = BoardProtocol.frameText(text, kind: .subtitle, maxWrite: 400)
        let s = try #require(String(data: f[0].dropFirst(2), encoding: .utf8))
        #expect(s == "…" + String(repeating: "ạ", count: 50))
    }

    @Test func timeFrameIsOneKind2Chunk() {
        let t = Date(timeIntervalSince1970: 1_761_400_000)
        let frame = BoardProtocol.timeFrame(at: t)
        #expect(Array(frame.prefix(2)) == [0x03, 2])
        let text = String(data: frame.dropFirst(2), encoding: .utf8)!
        #expect(text == BoardProtocol.timeText(at: t))
        #expect(text.range(of: #"^1761400000 -?\d+$"#, options: .regularExpression) != nil)
    }

    @Test func sliceWithNonZeroStartIndexParses() throws {
        let data = Data([9, 9, 1, 4, 0, 0, 0]).dropFirst(2)
        let i = try #require(BoardProtocol.parseBoardInfo(data))
        #expect(i == BoardInfo(protocolVersion: 1, fontSets: .cjk))
    }
}
