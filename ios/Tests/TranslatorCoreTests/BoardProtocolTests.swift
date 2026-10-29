import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/board/protocol_test.dart.

private func hex(_ d: Data) -> String {
    d.map { String(format: "%02x", $0) }.joined(separator: " ")
}

@Suite struct BoardProtocolTests {
    @Test func uuids() {
        #expect(BoardProtocol.serviceUUID == "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
        #expect(BoardProtocol.audioUUID == "A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
        #expect(BoardProtocol.textUUID == "A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
        #expect(BoardProtocol.controlUUID == "A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
        #expect(BoardProtocol.infoUUID == "A7C00005-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    }

    @Test func textKindCodes() {
        #expect(TextKind.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }

    // MARK: frameText

    @Test func tenBytesAt185IsOneChunkFlags03() {
        let f = BoardProtocol.frameText("0123456789", kind: .subtitle, maxWrite: 185)
        #expect(f.count == 1)
        #expect(f[0][0] == 0x03)
        #expect(f[0][1] == 0)
        #expect(f[0].count == 12)
    }

    @Test func oneHundredTwentyBytesAt50GivesPayload48ThreeChunks() {
        let f = BoardProtocol.frameText(String(repeating: "a", count: 120), kind: .status, maxWrite: 50)
        #expect(f.map { $0.first! } == [0x01, 0x00, 0x02])
        #expect(f.map { $0.count - 2 } == [48, 48, 24])
        #expect(f.allSatisfy { $0[$0.startIndex + 1] == 1 })
    }

    @Test func maxWrite10BehavesAs20() {
        let f = BoardProtocol.frameText(String(repeating: "a", count: 40), kind: .subtitle, maxWrite: 10)
        #expect(f.map { $0.count - 2 } == [18, 18, 4])
    }

    @Test func emptyTextIsOneChunkFlags03() {
        #expect(BoardProtocol.frameText("", kind: .subtitle, maxWrite: 185).map(hex) == ["03 00"])
    }

    @Test func longTextKeepsTheTailAfterAWordBoundaryWithEllipsis() throws {
        let text = (0..<40).map { String(format: "w%03d", $0) }.joined(separator: " ")
        #expect(text.utf8.count == 199)
        let f = BoardProtocol.frameText(text, kind: .subtitle, maxWrite: 400)
        #expect(f.count == 1)
        let s = try #require(String(data: f[0].dropFirst(2), encoding: .utf8))
        #expect(s.hasPrefix("…"))
        #expect(s.dropFirst().hasPrefix("w"))
        #expect(text.hasSuffix(String(s.dropFirst())))
        #expect(s.utf8.count <= 150 + 3)
    }

    @Test func longTextWithoutSpacesKeepsTheByteTail() throws {
        let text = String(repeating: "ạ", count: 100)  // 3 bytes each
        let f = BoardProtocol.frameText(text, kind: .subtitle, maxWrite: 400)
        let s = try #require(String(data: f[0].dropFirst(2), encoding: .utf8))
        #expect(s == "…" + String(repeating: "ạ", count: 50))
    }

    @Test func xinChaoKind0MatchesTheSwiftBytes() {
        #expect(BoardProtocol.frameText("Xin chào", kind: .subtitle, maxWrite: 185).map(hex)
            == ["03 00 58 69 6e 20 63 68 c3 a0 6f"])
    }

    @Test func labelKindIs3() {
        #expect(BoardProtocol.frameText("JA", kind: .label, maxWrite: 185).map(hex) == ["03 03 4a 41"])
    }

    // MARK: time

    @Test func timeTextIsUnixSecondsAndUTCOffsetMinutes() {
        let t = Date(timeIntervalSince1970: 1_761_400_000.999)
        #expect(BoardProtocol.timeText(at: t, in: TimeZone(identifier: "UTC")!) == "1761400000 0")
        #expect(BoardProtocol.timeText(at: t, in: TimeZone(secondsFromGMT: 7 * 3600)!) == "1761400000 420")
    }

    @Test func timeFrameIsOneKind2Chunk() {
        let t = Date(timeIntervalSince1970: 1_761_400_000)
        let frame = BoardProtocol.timeFrame(at: t)
        #expect(Array(frame.prefix(2)) == [0x03, 2])
        let text = String(data: frame.dropFirst(2), encoding: .utf8)!
        #expect(text == BoardProtocol.timeText(at: t))
        #expect(text.range(of: #"^1761400000 -?\d+$"#, options: .regularExpression) != nil)
    }

    // MARK: labelText

    @Test func labelCutsAtACharacterBoundaryNoEllipsis() {
        let s = BoardProtocol.labelText("日本語日本語日本語日本語")
        #expect(s.utf8.count == 30)
        #expect(s.unicodeScalars.count == 10)
    }

    @Test func shortLabelUnchanged() {
        #expect(BoardProtocol.labelText("Nhật") == "Nhật")
    }

    // MARK: parseBoardInfo

    @Test func versionAndFontSets() throws {
        let i = try #require(BoardProtocol.parseBoardInfo(Data([1, 3, 0, 0, 0])))
        #expect(i.protocolVersion == 1)
        #expect(i.fontSets == FontSets.latinVI | FontSets.latinExtA)
    }

    @Test func shortInputIsNil() {
        #expect(BoardProtocol.parseBoardInfo(Data([1, 3, 0, 0])) == nil)
    }

    @Test func littleEndianAcrossBytes() throws {
        let i = try #require(BoardProtocol.parseBoardInfo(Data([2, 0x10, 0x01, 0, 0])))
        #expect(i.fontSets.value == 0x0110)
    }

    @Test func sliceWithNonZeroStartIndexParses() throws {
        let data = Data([9, 9, 1, 4, 0, 0, 0]).dropFirst(2)
        let i = try #require(BoardProtocol.parseBoardInfo(data))
        #expect(i == BoardInfo(protocolVersion: 1, fontSets: .cjk))
    }
}
