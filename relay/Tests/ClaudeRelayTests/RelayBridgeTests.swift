import Foundation
import Testing
@testable import ClaudeRelay

/// A bridge with the Mac authenticated and the board's Claude service found (write size 20 + 1 flags byte)
private func linkedBridge(speech: String? = nil) -> RelayBridge {
    var b = RelayBridge()
    _ = b.handle(.speech(speech))
    _ = b.handle(.macUp)
    _ = b.handle(.boardUp(maxWrite: 21))
    _ = b.handle(.boardSubscribed(true))
    return b
}

private func packet(_ seq: UInt16) -> Data { Data([UInt8(seq & 0xff), UInt8(seq >> 8), 0, 0, 0, 0x11, 0x22]) }

@Test func noBoardSubscriptionWithoutTheMac() {
    var b = RelayBridge()
    #expect(b.handle(.boardUp(maxWrite: 185)).isEmpty)                 // no Mac: the board never sees a relay
    #expect(b.handle(.boardSubscribed(true)).isEmpty)
    #expect(b.handle(.boardInput(Data([9, 0, 0, 0, 0x32]))).isEmpty)
    #expect(!b.linked)
    #expect(b.handle(.macUp) == [.subscribeBoard(true)])
}

@Test func linkUpSaysHelloThenTellsTheMac() {
    var b = RelayBridge()
    _ = b.handle(.speech(nil))
    #expect(b.handle(.macUp).isEmpty)                                  // no board yet
    #expect(b.handle(.boardUp(maxWrite: 185)) == [.subscribeBoard(true)])
    let actions = b.handle(.boardSubscribed(true))
    #expect(actions == [.writeBoard(Data([0x03]) + BoardHello.relay), .toMac(.boardLink(true)),
                        .toMac(.voiceStatus(nil)), .subscribeVoice(true)])
    #expect(b.linked)
}

@Test func framesPassThroughUnchanged() {
    var b = linkedBridge()
    let message = Data([0]) + Data([4, 3, 2, 1]) + Data(String(repeating: "dự án ", count: 60).utf8.prefix(400))
    let writes = b.handle(.mac(.toBoard(message))).compactMap { if case .writeBoard(let d) = $0 { d } else { nil } }
    #expect(writes.count > 1 && writes.first!.first == 0x01 && writes.last!.first! & 0x02 != 0)
    #expect(writes.reduce(Data()) { $0 + $1.dropFirst() } == message)   // exactly the Mac's bytes
    #expect(b.handle(.boardInput(Data([4, 3, 2, 1, 1]))) == [.toMac(.fromBoard(Data([4, 3, 2, 1, 1])))])
    #expect(b.handle(.boardInput(Data([1, 2, 3]))).isEmpty)            // not a board input
    #expect(b.handle(.boardInput(Data(count: 11))).isEmpty)
}

@Test func macDownUnsubscribesAndBoardDownTellsTheMac() {
    var b = linkedBridge()
    #expect(b.handle(.boardSubscribed(false)) == [.toMac(.boardLink(false))])
    var c = linkedBridge()
    #expect(c.handle(.macDown) == [.subscribeBoard(false), .subscribeVoice(false)])
    #expect(c.handle(.mac(.toBoard(Data([2, 1, 0, 0, 0])))).isEmpty)
    var d = linkedBridge()
    #expect(d.handle(.boardDown) == [.toMac(.boardLink(false))])
    #expect(d.handle(.boardUp(maxWrite: 185)) == [.subscribeBoard(true)])
}

@Test func earlyAudioIsFedAtBegin() {
    var b = linkedBridge()
    for s: UInt16 in 0..<3 { #expect(b.handle(.boardVoice(packet(s))).isEmpty) }   // before the Mac's begin
    #expect(b.handle(.mac(.voiceBegin(7))) == [.transcribeBegin(7), .transcribeFeed(packet(0)),
                                                .transcribeFeed(packet(1)), .transcribeFeed(packet(2))])
    #expect(b.handle(.boardVoice(packet(3))) == [.transcribeFeed(packet(3))])
    #expect(b.handle(.mac(.voiceFinish(7))) == [.transcribeFinish(7)])
    #expect(b.handle(.boardVoice(packet(4))).isEmpty)                   // after finish: buffered, not fed
    #expect(b.handle(.transcript(7, final: false, "xin")) == [.toMac(.transcript(7, final: false, "xin"))])
    #expect(b.handle(.transcript(7, final: true, "Xin chào")) == [.toMac(.transcript(7, final: true, "Xin chào"))])
    #expect(b.handle(.transcript(7, final: true, "again")).isEmpty)    // the session is over
}

@Test func aNewCaptureStopsFeedingTheOldSession() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.boardVoice(packet(0))) == [.transcribeFeed(packet(0))])
    #expect(b.handle(.boardVoice(packet(1))) == [.transcribeFeed(packet(1))])
    // The board restarted (Say again) before the Mac's cancel arrived: seq 0 again
    #expect(b.handle(.boardVoice(packet(0))).isEmpty)
    #expect(b.handle(.boardVoice(packet(1))).isEmpty)
    #expect(b.handle(.mac(.voiceCancel(7))) == [.transcribeCancel])
    #expect(b.handle(.mac(.voiceBegin(8))) == [.transcribeBegin(8), .transcribeFeed(packet(0)), .transcribeFeed(packet(1))])
}

@Test func staleAndForeignVoiceTrafficIsIgnored() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.mac(.voiceFinish(6))).isEmpty)
    #expect(b.handle(.mac(.voiceCancel(6))).isEmpty)
    #expect(b.handle(.transcript(6, final: true, "old")).isEmpty)
    #expect(b.handle(.transcriptFailed(6, "old")).isEmpty)
    #expect(b.handle(.transcriptFailed(7, "Transcription did not start")) == [.toMac(.voiceFailed(7, "Transcription did not start"))])
    #expect(b.handle(.boardVoice(Data([0, 0]))).isEmpty)              // not an audio packet
}

@Test func beginWithoutSpeechFails() {
    var b = linkedBridge(speech: "Allow Speech Recognition for Live Translator on the iPhone")
    #expect(b.handle(.mac(.voiceBegin(3)))
            == [.toMac(.voiceFailed(3, "Allow Speech Recognition for Live Translator on the iPhone"))])
}

@Test func speechChangesReachTheMacAndTheVoiceSubscription() {
    var b = linkedBridge(speech: "not ready")
    #expect(b.handle(.speech(nil)) == [.toMac(.voiceStatus(nil)), .subscribeVoice(true)])
    #expect(b.handle(.speech("gone")) == [.toMac(.voiceStatus("gone")), .subscribeVoice(false)])
    var unlinked = RelayBridge()
    #expect(unlinked.handle(.speech(nil)).isEmpty)
}

@Test func linkLossCancelsTranscription() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.boardSubscribed(false)) == [.toMac(.boardLink(false)), .transcribeCancel])
}

@Test func longTranscriptsAreCut() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    let long = String(repeating: "chào ", count: 400)
    guard case .toMac(.transcript(7, true, let sent))? = b.handle(.transcript(7, final: true, long)).first else {
        Issue.record("no transcript"); return
    }
    #expect(sent.utf8.count <= RelayFrame.maxText && long.hasPrefix(sent))
}

@Test func audioBufferKeepsOneCapture() {
    var a = VoiceAudioBuffer()
    a.append(packet(0)); a.append(packet(1))
    a.append(packet(0))                                                  // a new capture
    #expect(a.packets == [packet(0)])
    for s in 1..<2000 { a.append(packet(UInt16(s))) }
    #expect(a.packets.count == VoiceAudioBuffer.maxPackets)
    #expect(a.take().count == VoiceAudioBuffer.maxPackets && a.packets.isEmpty)
}
