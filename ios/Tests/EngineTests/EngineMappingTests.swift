import AVFAudio
import XCTest
@testable import TranslatorCore

/// The pure pieces between the iOS frameworks and the engine messages: event construction, errors, PCM, and the
/// event streams. Moved from app/ios/RunnerTests/EngineMappingTests.swift.
final class EngineMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000.5)

    func testMinePartialEndsWhenItArrivesAndStartsItsAudioLengthEarlier() {
        let msg = EngineMapping.mine(.partial("xin chào", audio: 1.25), now: now)
        XCTAssertEqual(msg.kind, .partial)
        XCTAssertEqual(msg.text, "xin chào")
        XCTAssertEqual(msg.endMs, 1_700_000_000_500)
        XCTAssertEqual(msg.startMs, 1_700_000_000_500 - 1250)
    }

    func testMineFinalIsFinalText() {
        let msg = EngineMapping.mine(.final("cảm ơn", confidence: nil, audio: 0.5), now: now)
        XCTAssertEqual(msg.kind, .finalText)
        XCTAssertEqual(msg.text, "cảm ơn")
        XCTAssertEqual(msg.endMs - msg.startMs, 500)
    }

    func testTheirsCarriesConfidenceAndGeneration() {
        let msg = EngineMapping.theirs(.final("good morning", confidence: 0.81, audio: 1), generation: 7)
        XCTAssertEqual(msg, TheirsMsg(text: "good morning", confidence: 0.81, generation: 7))
        XCTAssertEqual(EngineMapping.theirs(.final("hi", confidence: nil, audio: 1), generation: 2)?.confidence, nil)
    }

    func testTheirsDropsPartialsAndEmptyFinals() {
        XCTAssertNil(EngineMapping.theirs(.partial("good mor", audio: 1), generation: 1))
        XCTAssertNil(EngineMapping.theirs(.final("", confidence: 0.9, audio: 0), generation: 1))
    }

    func testPcm16BufferHoldsTheSamples() throws {
        let buffer = try XCTUnwrap(EngineMapping.pcm16Buffer([1, 32767, -32768], sampleRate: 16_000))
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.frameLength, 3)
        let p = try XCTUnwrap(buffer.int16ChannelData?[0])
        XCTAssertEqual([p[0], p[1], p[2]], [1, 32767, -32768])
    }

    func testPcm16BufferRejectsEmptyInputOrNoRate() {
        XCTAssertNil(EngineMapping.pcm16Buffer([], sampleRate: 16_000))
        XCTAssertNil(EngineMapping.pcm16Buffer([1], sampleRate: 0))
    }

    func testLanguageCodeOfLocaleIdentifiers() {
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "en_US")), "en")
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "vi-VN")), "vi")
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "ja")), "ja")
    }

    func testErrorsAreTheCoreEngineErrors() {
        XCTAssertEqual(EngineErrors.translateFailed("x"), .translateFailed)
        XCTAssertEqual(EngineErrors.notReady("x"), .notReady)
        XCTAssertEqual(EngineErrors.downloadFailed("x"), .downloadFailed)
        XCTAssertEqual(String(describing: DownloadFailure("why")), "why")
    }

    func testRecognizerKindNameIsTheCoreOne() {
        XCTAssertEqual(RecognizerKind(rawValue: RecognizerKinds.onDevice), .osOnDevice)
    }

    /// Events sent from any thread reach every subscriber, each stream in the order it was sent
    func testEventsFromAnyThreadArriveInOrderPerStream() async {
        let sink = EngineEventSink()
        let first = EventRecorder(sink), second = EventRecorder(sink)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                sink.send(.gate(true))
                for i in 0..<50 { sink.send(.ttsStart(i)) }
                sink.send(.gate(false))
                sink.send(.ttsEnd(99))
                done.resume()
            }
        }
        await settle()
        for recorder in [first, second] {
            let starts = recorder.all.compactMap { if case .ttsStart(let id) = $0 { return id } else { return nil } }
            let gates = recorder.all.compactMap { if case .gate(let open) = $0 { return open } else { return nil } }
            XCTAssertEqual(starts, Array(0..<50))
            XCTAssertEqual(gates, [true, false])
            XCTAssertTrue(recorder.all.contains(.ttsEnd(99)))
        }
    }
}
