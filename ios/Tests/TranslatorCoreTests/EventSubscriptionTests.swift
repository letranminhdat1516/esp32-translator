import Foundation
import Testing
@testable import TranslatorCore

// Subscribing to engine and board events: events() bundles, Broadcast buffering and finish.

@Suite struct EngineEventsTests {
    /// The natural consumer pattern: subscribe, then hand the streams to a Task. `events()` subscribes to every
    /// stream before returning, so an event sent before the Task first runs is not lost.
    @Test func eventsSubscribedBeforeTheTaskRunsKeepEarlyEvents() async {
        let engine = FakeVoiceEngine()
        let ev = engine.events()
        let task = Task { () -> [Int] in
            var got: [Int] = []
            for await id in ev.ttsStart { got.append(id) }
            return got
        }
        engine.emitTtsStart(7)
        engine.finishEvents()
        #expect(await task.value == [7])
    }

    @Test func eventsCoverEveryStream() async {
        let engine = FakeVoiceEngine()
        let ev = engine.events()
        engine.emitMine(MineMsg(kind: .partial, text: "a", startMs: 0, endMs: 1))
        engine.emitTheirs(TheirsMsg(text: "b", confidence: 0.5, generation: 1))
        engine.emitGate(false)
        engine.emitTtsStart(1)
        engine.emitTtsEnd(2)
        engine.emitAudioSession(AudioSessionMsg(kind: .interrupted))
        engine.emitDownload(DownloadMsg(item: MissingMsg(kind: .ttsVoice, language: "vi"), progress: 0.5, done: false,
                                        error: nil))
        var mine = ev.mine.makeAsyncIterator()
        var theirs = ev.theirs.makeAsyncIterator()
        var gate = ev.gate.makeAsyncIterator()
        var ttsStart = ev.ttsStart.makeAsyncIterator()
        var ttsEnd = ev.ttsEnd.makeAsyncIterator()
        var session = ev.audioSession.makeAsyncIterator()
        var download = ev.download.makeAsyncIterator()
        #expect(await mine.next()?.text == "a")
        #expect(await theirs.next()?.text == "b")
        #expect(await gate.next() == false)
        #expect(await ttsStart.next() == 1)
        #expect(await ttsEnd.next() == 2)
        #expect(await session.next()?.kind == .interrupted)
        #expect(await download.next()?.progress == 0.5)
    }
}

@Suite struct BoardEventsTests {
    @Test func eventsSubscribedBeforeTheTaskRunsKeepEarlyEvents() async {
        let link = FakeBoardLink()
        let ev = link.events()
        let task = Task { () -> [BoardState] in
            var got: [BoardState] = []
            for await s in ev.state { got.append(s) }
            return got
        }
        link.emitState(.ready)
        link.finishEvents()
        #expect(await task.value == [.ready])
    }

    @Test func eventsCoverAudioAndControl() async {
        let link = FakeBoardLink()
        let ev = link.events()
        link.emitAudio(Data([2]))
        link.emitControl(.micChanged(false))
        var audio = ev.audio.makeAsyncIterator()
        var control = ev.control.makeAsyncIterator()
        #expect(await audio.next() == Data([2]))
        #expect(await control.next() == .micChanged(false))
    }

    @Test func currentStateLetsALateSubscriberSeeReady() {
        let link = FakeBoardLink()
        #expect(link.currentState == .off)
        link.emitState(.connecting)
        link.emitState(.ready)
        let late: any BoardLink = link
        #expect(late.currentState == .ready)
    }

    @Test func audioKeepsOnlyTheNewest64Packets() async {
        let link = FakeBoardLink()
        let audio = link.audio
        for i in 0..<70 { link.emitAudio(Data([UInt8(i)])) }
        link.finishEvents()
        var got: [UInt8] = []
        for await packet in audio { got.append(packet[packet.startIndex]) }
        #expect(got == (6..<70).map { UInt8($0) })
    }

    @Test func controlIsUnbounded() async {
        let link = FakeBoardLink()
        let control = link.control
        for i in 0..<100 { link.emitControl(.micChanged(i % 2 == 0)) }
        link.finishEvents()
        var count = 0
        for await _ in control { count += 1 }
        #expect(count == 100)
    }
}

@Suite struct BroadcastTests {
    @Test func streamAfterFinishIsAlreadyFinished() async {
        let b = Broadcast<Int>()
        b.finish()
        var it = b.stream().makeAsyncIterator()
        b.send(1)
        #expect(await it.next() == nil)
    }

    @Test func finishEndsCurrentSubscribersAfterTheirBufferedElements() async {
        let b = Broadcast<Int>()
        let s = b.stream()
        b.send(1)
        b.finish()
        var got: [Int] = []
        for await x in s { got.append(x) }
        #expect(got == [1])
    }

    @Test func bufferingNewestKeepsTheLatest() async {
        let b = Broadcast<Int>(bufferingPolicy: .bufferingNewest(64))
        let s = b.stream()
        for i in 0..<70 { b.send(i) }
        b.finish()
        var got: [Int] = []
        for await x in s { got.append(x) }
        #expect(got == Array(6..<70))
    }

    @Test func defaultBufferingIsUnbounded() async {
        let b = Broadcast<Int>()
        let s = b.stream()
        for i in 0..<1000 { b.send(i) }
        b.finish()
        var count = 0
        for await _ in s { count += 1 }
        #expect(count == 1000)
    }
}
