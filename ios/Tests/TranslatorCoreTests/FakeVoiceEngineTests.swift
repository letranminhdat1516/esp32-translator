import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/engine/fake_voice_engine_test.dart (the pigeon codec cases have no Swift counterpart:
// the Swift engine is in-process).

@Suite struct FakeVoiceEngineTests {
    @Test func recordsSpeakCallsInOrder() async throws {
        let engine = FakeVoiceEngine()
        try await engine.speak("xin chào", id: 1)
        try await engine.speak("hello", id: 2)
        let spoken = await engine.spoken
        #expect(spoken.map(\.text) == ["xin chào", "hello"])
        #expect(spoken.map(\.id) == [1, 2])
    }

    @Test func failNextTranslateThrowsOnceThenTranslationsResume() async throws {
        let engine = FakeVoiceEngine()
        await engine.setTranslation("chào", for: "hi")
        await engine.failNextTranslate()
        await #expect(throws: EngineError.translateFailed) {
            try await engine.translate("hi", from: "en", to: "vi")
        }
        #expect(try await engine.translate("hi", from: "en", to: "vi") == "chào")
        #expect(try await engine.translate("unknown", from: "en", to: "vi") == "unknown")
    }

    @Test func emittedEventsArriveOnTheStreams() async {
        let engine = FakeVoiceEngine()
        let mine = MineMsg(kind: .finalText, text: "a", startMs: 0, endMs: 10)
        let theirs = TheirsMsg(text: "b", confidence: nil, generation: 3)
        var mineIt = engine.mine.makeAsyncIterator()
        var theirsIt = engine.theirs.makeAsyncIterator()
        var gateIt = engine.gate.makeAsyncIterator()
        var ttsStartIt = engine.ttsStart.makeAsyncIterator()
        var ttsEndIt = engine.ttsEnd.makeAsyncIterator()
        var sessionIt = engine.audioSession.makeAsyncIterator()
        var downloadIt = engine.download.makeAsyncIterator()
        engine.emitMine(mine)
        engine.emitTheirs(theirs)
        engine.emitGate(true)
        engine.emitTtsStart(7)
        engine.emitTtsEnd(7)
        engine.emitAudioSession(AudioSessionMsg(kind: .routeChanged, route: .phoneMic))
        let item = MissingMsg(kind: .translation, language: "ja", from: "ja", to: "vi")
        engine.emitDownload(DownloadMsg(item: item, progress: 1, done: true, error: nil))
        #expect(await mineIt.next() == mine)
        #expect(await theirsIt.next() == theirs)
        #expect(await gateIt.next() == true)
        #expect(await ttsStartIt.next() == 7)
        #expect(await ttsEndIt.next() == 7)
        #expect(await sessionIt.next() == AudioSessionMsg(kind: .routeChanged, route: .phoneMic))
        #expect(await downloadIt.next()?.item == item)
    }

    @Test func recordsCallsAndReturnsScriptedResults() async throws {
        let caps = Capabilities(recognizers: ["ja": [.whisper]], translatable: ["ja", "vi"], vietnameseVoice: false)
        let engine = FakeVoiceEngine(capabilities: caps)
        let item = MissingMsg(kind: .speechModel, language: "ja")
        await engine.setMissing([item])
        let pair = PairMsg(home: "vi", other: "ja", generation: 2)

        #expect(try await engine.capabilities(home: "vi") == caps)
        #expect(try await engine.missing(pair: pair) == [item])
        try await engine.downloadItem(item)
        try await engine.start(pair: pair, recognizerX: "whisper", hints: ["Bến Thành"])
        try await engine.micOn(true)
        try await engine.feedTheirAudio([1, -1], sampleRate: 16_000)
        try await engine.setHints(["a"])
        try await engine.stopSpeaking()
        try await engine.openTtsSettings()
        try await engine.stop()

        #expect(await engine.capabilitiesHomes == ["vi"])
        #expect(await engine.missingPairs == [pair])
        #expect(await engine.downloaded == [item])
        let starts = await engine.starts
        #expect(starts.map(\.pair) == [pair])
        #expect(starts.map(\.recognizerX) == ["whisper"])
        #expect(starts.map(\.hints) == [["Bến Thành"]])
        #expect(await engine.micStates == [true])
        #expect(await engine.fed.map(\.pcm) == [[1, -1]])
        #expect(await engine.fed.map(\.sampleRate) == [16_000])
        #expect(await engine.hints == ["a"])
        #expect(await engine.stopSpeakingCount == 1)
        #expect(await engine.openTtsSettingsCount == 1)
        #expect(await engine.stopCount == 1)
    }

    @Test func capabilitiesMsgToModelMapsRecognizerNames() throws {
        let msg = CapabilitiesMsg(
            recognizers: [RecognizerEntryMsg(language: "ja", kinds: ["whisper", "osOnline"])],
            translatable: ["ja", "vi"],
            vietnameseVoice: false
        )
        #expect(try msg.toModel() == Capabilities(
            recognizers: ["ja": [.whisper, .osOnline]], translatable: ["ja", "vi"], vietnameseVoice: false))
        let bad = CapabilitiesMsg(
            recognizers: [RecognizerEntryMsg(language: "ja", kinds: ["telepathy"])], translatable: [], vietnameseVoice: true)
        #expect(throws: (any Error).self) { try bad.toModel() }
    }

    @Test func engineErrorFromCode() {
        #expect(EngineError(code: "notReady") == .notReady)
        #expect(EngineError(code: "translateFailed") == .translateFailed)
        #expect(EngineError(code: "downloadFailed") == .downloadFailed)
        #expect(EngineError(code: "nope") == nil)
    }

    @Test func usableThroughTheProtocol() async throws {
        let engine: any VoiceEngine = FakeVoiceEngine()
        #expect(try await engine.capabilities(home: "vi").vietnameseVoice)
    }
}
