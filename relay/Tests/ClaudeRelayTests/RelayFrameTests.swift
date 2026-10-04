import Foundation
import Testing
@testable import ClaudeRelay

@Test func frameVectors() {
    #expect(RelayFrame.toBoard(Data([2, 9, 0, 0, 0])).encode() == Data([0x01, 2, 9, 0, 0, 0]))
    #expect(RelayFrame.transcript(7, final: true, "Xin chào").encode() == Data([0x13, 7, 0, 0, 0, 1]) + Data("Xin chào".utf8))
    #expect(RelayFrame.boardLink(true).encode() == Data([0x03, 1]))
    #expect(RelayFrame.voiceStatus(nil).encode() == Data([0x04, 0]))
    #expect(RelayFrame.voiceStatus("No model").encode() == Data([0x04, 1]) + Data("No model".utf8))
    #expect(RelayFrame.voiceBegin(5).encode() == Data([0x10, 5, 0, 0, 0]))
}

@Test func everyFrameRoundTripsFromItsSender() {
    let frames: [RelayFrame] = [
        .toBoard(Data([0, 1, 0, 0, 0]) + Data("p\nBash\nls".utf8)), .fromBoard(Data([4, 3, 2, 1, 1])),
        .boardLink(false), .boardLink(true), .voiceStatus(nil), .voiceStatus("Allow Speech Recognition"),
        .voiceBegin(1), .voiceFinish(0xffff_ffff), .voiceCancel(9),
        .transcript(3, final: false, "đang nói"), .transcript(3, final: true, ""), .voiceFailed(3, "no model"),
        .challenge(Data([1]) + Data(repeating: 0x11, count: 32)),
        .auth(nonce: Data(repeating: 0x22, count: 32), proof: Data(repeating: 0x33, count: 32)),
        .welcome(Data(repeating: 0x44, count: 32)),
    ]
    for f in frames {
        #expect(RelayFrame.decode(f.encode(), from: f.sender) == f, "\(f)")
    }
}

@Test func framesAreDirectionChecked() {
    // A Mac frame claimed by the phone (and the reverse) is refused
    #expect(RelayFrame.decode(RelayFrame.toBoard(Data([2, 9, 0, 0, 0])).encode(), from: .phone) == nil)
    #expect(RelayFrame.decode(RelayFrame.fromBoard(Data([9, 0, 0, 0, 0x32])).encode(), from: .mac) == nil)
    #expect(RelayFrame.decode(RelayFrame.voiceBegin(5).encode(), from: .phone) == nil)
    #expect(RelayFrame.decode(RelayFrame.welcome(Data(count: 32)).encode(), from: .phone) == nil)
}

@Test func malformedFramesAreRefused() {
    let bad: [(Data, RelayFrame.Sender)] = [
        (Data(), .mac),
        (Data([0x01, 2, 9, 0, 0]), .mac),                                        // board message shorter than 5
        (Data([0x01]) + Data(count: 406), .mac),                                 // longer than 405
        (Data([0x02, 1, 2, 3, 4]), .phone),                                      // input shorter than 5
        (Data([0x02]) + Data(count: 11), .phone),                                // input longer than 10
        (Data([0x03, 2]), .phone), (Data([0x03]), .phone), (Data([0x03, 1, 1]), .phone),
        (Data([0x04, 1]), .phone),                                               // a reason flag without a reason
        (Data([0x04, 0, 0x41]), .phone),                                         // ready with trailing bytes
        (Data([0x10, 0, 0, 0, 0]), .mac),                                        // session 0
        (Data([0x11, 1, 0, 0]), .mac),                                           // short session
        (Data([0x13, 1, 0, 0, 0, 2]), .phone),                                   // final flag 2
        (Data([0x13, 1, 0, 0, 0, 1, 0xff, 0xfe]), .phone),                       // invalid UTF-8
        (Data([0x13, 1, 0, 0, 0, 1]) + Data(repeating: 0x41, count: 1001), .phone),
        (Data([0x14, 1, 0, 0, 0]), .phone),                                      // empty reason
        (Data([0x20, 2]) + Data(count: 32), .mac),                               // unknown version
        (Data([0x20, 1]) + Data(count: 31), .mac),
        (Data([0x21]) + Data(count: 63), .phone),
        (Data([0x22]) + Data(count: 33), .mac),
        (Data([0x7f, 0]), .mac),                                                 // unknown type
        (Data([0x01]) + Data(count: 2048), .mac),                                // over maxFrame
    ]
    for (d, s) in bad { #expect(RelayFrame.decode(d, from: s) == nil, "\([UInt8](d.prefix(8)))") }
}

@Test func fitCutsAtCharacterBoundaries() {
    #expect(RelayFrame.fit("chào", maxBytes: 4) == "chà")    // c h à(2 bytes) = 4
    #expect(RelayFrame.fit("chào", maxBytes: 3) == "ch")     // "à" never split
    #expect(RelayFrame.fit("abc", maxBytes: 10) == "abc")
    #expect(RelayFrame.fit("", maxBytes: 0) == "")
}

@Test func onlyFramesThePeerWouldAcceptGoOnTheWire() {
    // The sender's own, well-formed frames: the same bytes as encode()
    #expect(RelayFrame.boardLink(true).wire(from: .phone) == RelayFrame.boardLink(true).encode())
    #expect(RelayFrame.voiceBegin(4).wire(from: .mac) == RelayFrame.voiceBegin(4).encode())
    // Wrong direction, or a frame decode would refuse (the peer would close the connection): nothing to send
    #expect(RelayFrame.toBoard(Data([0, 1, 0, 0, 0])).wire(from: .phone) == nil)
    #expect(RelayFrame.toBoard(Data([0, 1])).wire(from: .mac) == nil)
    #expect(RelayFrame.voiceBegin(0).wire(from: .mac) == nil)
    #expect(RelayFrame.voiceStatus("").wire(from: .phone) == nil)
    #expect(RelayFrame.transcript(1, final: true, String(repeating: "a", count: 1001)).wire(from: .phone) == nil)
}

@Test func oversizedInputIsRefusedBeforeCopying() {
    #expect(RelayFrame.decode(Data([0x13]) + Data(count: 1 << 20), from: .phone) == nil)
}
