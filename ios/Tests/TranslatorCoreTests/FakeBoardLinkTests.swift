import Foundation
import Testing
@testable import TranslatorCore

@Suite struct FakeBoardLinkTests {
    @Test func recordsTextsAndMicCallsInOrder() async {
        let link = FakeBoardLink()
        await link.sendText("a", kind: .subtitle)
        await link.sendText("b", kind: .label)
        await link.setBoardMic(true)
        await link.setBoardMic(false)
        #expect(link.sentTexts.map(\.text) == ["a", "b"])
        #expect(link.sentTexts.map(\.kind) == [.subtitle, .label])
        #expect(link.micCalls == [true, false])
    }

    @Test func defaultInfoAndSettableInfo() {
        let link = FakeBoardLink()
        #expect(link.info == BoardInfo(protocolVersion: 0, fontSets: .latinVI))
        link.info = BoardInfo(protocolVersion: 1, fontSets: .cjk)
        #expect(link.info.protocolVersion == 1)
    }

    @Test func emitsStateAudioAndControl() async {
        let link = FakeBoardLink()
        var states = link.state.makeAsyncIterator()
        var audio = link.audio.makeAsyncIterator()
        var control = link.control.makeAsyncIterator()
        link.emitState(.ready)
        link.emitAudio(Data([1]))
        link.emitControl(.micChanged(true))
        #expect(await states.next() == .ready)
        #expect(await audio.next() == Data([1]))
        #expect(await control.next() == .micChanged(true))
    }

    @Test func everySubscriberGetsEveryEvent() async {
        let link = FakeBoardLink()
        var a = link.state.makeAsyncIterator()
        var b = link.state.makeAsyncIterator()
        link.emitState(.scanning)
        link.emitState(.ready)
        #expect(await a.next() == .scanning)
        #expect(await a.next() == .ready)
        #expect(await b.next() == .scanning)
        #expect(await b.next() == .ready)
    }

    @Test func usableThroughTheProtocol() async {
        let link: any BoardLink = FakeBoardLink()
        await link.sendText("x", kind: .time)
        #expect(link.info.fontSets == .latinVI)
    }
}
