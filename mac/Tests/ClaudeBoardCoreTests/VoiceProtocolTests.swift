import Foundation
import Testing
@testable import ClaudeBoardCore

@Test func voiceInputsDecodeTheSharedVectors() {
    #expect(BoardInput.decode(Data([0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01]))
            == .voiceStart(voice: 0x0A0B0C0D, purpose: .other(question: 2), target: 0x01020304))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0])) == .voiceStart(voice: 9, purpose: .command, target: 5))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x30, 0x02, 7, 0, 0, 0])) == .voiceStart(voice: 9, purpose: .denyReason, target: 7))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x31])) == .voiceStop(voice: 9))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x32])) == .voiceCancel(voice: 9))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x33])) == .voiceSend(voice: 9))
    // Other answers ride on the unchanged answers input (bit 7)
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 0x10, 2, 0x80, 0x05])) == .answers(id: 0x01020304, masks: [0x80, 0x05]))
}

@Test func voiceInputsRejectBadShapes() {
    let bad: [[UInt8]] = [
        [0, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0],      // voice id 0
        [9, 0, 0, 0, 0x30, 0x00, 0, 0, 0, 0],      // target 0
        [9, 0, 0, 0, 0x30, 0x03, 5, 0, 0, 0],      // unknown purpose
        [9, 0, 0, 0, 0x30, 0x10, 5, 0, 0, 0],      // command with a question index
        [9, 0, 0, 0, 0x30, 0x12, 5, 0, 0, 0],      // deny reason with a question index
        [9, 0, 0, 0, 0x30, 0x41, 5, 0, 0, 0],      // Other for question 4 (max 4 questions: 0...3)
        [9, 0, 0, 0, 0x30, 0x00, 5, 0, 0],         // short
        [9, 0, 0, 0, 0x31, 0],                     // stop with a trailing byte
        [0, 0, 0, 0, 0x33],                        // send for voice 0
    ]
    for b in bad { #expect(BoardInput.decode(Data(b)) == nil, "\(b)") }
}

@Test func voiceMessageEncodesKind8() {
    let final = BoardMessage.voice(id: 9, .final("Xin chào")).encode()
    #expect(final == Data([8, 9, 0, 0, 0]) + Data("f\nXin chào".utf8))
    #expect(BoardMessage.voice(id: 9, .partial("a")).encode() == Data([8, 9, 0, 0, 0]) + Data("p\na".utf8))
    #expect(BoardMessage.voice(id: 9, .error("No\npane")).encode() == Data([8, 9, 0, 0, 0]) + Data("x\nNo pane".utf8))
    #expect(BoardMessage.voice(id: 9, .done("Sent")).encode() == Data([8, 9, 0, 0, 0]) + Data("k\nSent".utf8))
    #expect(BoardMessage.voice(id: 9, .final("")).encode() == Data([8, 9, 0, 0, 0]) + Data("f\n".utf8))
}

@Test func longPartialKeepsItsEnd() {
    let words = (1...200).map { "từ\($0)" }.joined(separator: " ")
    let d = BoardMessage.voice(id: 1, .partial(words)).encode()
    let text = String(decoding: d.dropFirst(5), as: UTF8.self)
    #expect(d.count - 5 <= BoardMessage.textMax)
    #expect(text.hasPrefix("p\n…") && text.hasSuffix("từ200"))
}

@Test func fitTailKeepsWholeCharactersAtTheEnd() {
    #expect(Utf8.fitTail("abc", maxBytes: 3) == "abc")
    #expect(Utf8.fitTail("abcdef", maxBytes: 5) == "…ef")
    #expect(Utf8.fitTail("xin chào", maxBytes: 7) == "…hào")     // "…" (3) + "hào" (4: "à" is 2 bytes)
    #expect(Utf8.fitTail("abcdef", maxBytes: 2) == "")
}

@Test func sessionRowCarriesTheVoiceFlag() {
    let r = SessionRow(handle: 5, state: .working, since: 1_759_555_200, updated: 1_759_555_260,
                       focused: true, unseen: false, project: "dự-án", lastLine: "Done.", voice: true)
    #expect(r.flags == 5)
    #expect(BoardMessage.session(r).encode() == Data([4, 5, 0, 0, 0]) + Data("w 1759555200 1759555260 5\ndự-án\nDone.".utf8))
    let plain = SessionRow(handle: 5, state: .idle, since: 1, updated: 2, focused: false, unseen: true,
                           project: "p", lastLine: "")
    #expect(!plain.voice && plain.flags == 2)
}

@Test func forTypingCleansAndCaps() {
    #expect(VoiceText.forTyping("  chạy\tcác bài\r\nkiểm tra  ") == "chạy các bài kiểm tra")
    #expect(VoiceText.forTyping("!rm -rf /") == "rm -rf /")                  // never bash mode
    #expect(VoiceText.forTyping("/clear") == "clear")                        // never a slash command
    #expect(VoiceText.forTyping(" # note") == "note")                        // never memory mode
    #expect(VoiceText.forTyping("! / #") == "")                              // nothing left: never typed
    #expect(VoiceText.forTyping("“Chạy” ‘test’") == "\"Chạy\" 'test'")
    #expect(VoiceText.forTyping("a\u{202E}b\u{2066}c\u{200F}") == "abc")     // bidi controls dropped
    #expect(VoiceText.forTyping("a\u{2028}b\u{0}c") == "a b c")
    #expect(VoiceText.forTyping("-x {a} ok;") == "-x {a} ok;")               // tmux escaping is Task 2's job
    let long = String(repeating: "ữ", count: 150)                            // 450 bytes
    let capped = VoiceText.forTyping(long)
    #expect(capped.utf8.count == 300 && capped == String(repeating: "ữ", count: 100))
    let spaced = String(repeating: "ab ", count: 120)                        // the cut lands after a space
    #expect(!VoiceText.forTyping(spaced).hasSuffix(" ") && VoiceText.forTyping(spaced).utf8.count <= 300)
}

@Test func adpcmDecodesTheSharedVector() {
    var d = ADPCMDecoder()
    #expect(d.decode(Data([0, 0, 0, 0, 0, 0x07])) == [11, 13])
}

@Test func adpcmFillsSmallGapsWithSilence() {
    var d = ADPCMDecoder()
    _ = d.decode(Data([0, 0, 0, 0, 0, 0x07]))
    let next = d.decode(Data([3, 0, 0, 0, 0, 0x07]))          // seq 1 and 2 lost: 2 packets × 2 samples of silence
    #expect(next == [0, 0, 0, 0, 11, 13])
    d.reset()
    #expect(d.decode(Data([9, 0, 0, 0, 0, 0x07])) == [11, 13])   // after reset: no gap fill
    #expect(d.decode(Data([1, 2, 3])) == [])                     // shorter than a header: nothing
}
