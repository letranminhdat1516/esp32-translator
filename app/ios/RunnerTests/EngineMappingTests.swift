import AVFAudio
import Speech
import Translation
import XCTest
@testable import Runner

/// The pure pieces between the iOS frameworks and the pigeon messages: event construction, errors, audio
/// routes and PCM, and the in-order, main-thread event delivery.
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

    func testRouteIsHeadsetForBluetoothAndWiredMics() {
        XCTAssertEqual(EngineMapping.route(inputs: [.bluetoothHFP]), .headset)
        XCTAssertEqual(EngineMapping.route(inputs: [.headsetMic]), .headset)
        XCTAssertEqual(EngineMapping.route(inputs: [.builtInMic]), .phoneMic)
        XCTAssertEqual(EngineMapping.route(inputs: []), .phoneMic)
    }

    func testOnlyDeviceChangesAreReportedAsRouteChanges() {
        XCTAssertTrue(EngineMapping.reportsRouteChange(.newDeviceAvailable))
        XCTAssertTrue(EngineMapping.reportsRouteChange(.oldDeviceUnavailable))
        // Our own setCategory calls change the category: not a route change for Dart
        XCTAssertFalse(EngineMapping.reportsRouteChange(.categoryChange))
    }

    func testPcm16BufferReadsLittleEndianSamples() throws {
        let bytes = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])  // 1, 32767, -32768
        let buffer = try XCTUnwrap(EngineMapping.pcm16Buffer(bytes, sampleRate: 16_000))
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.frameLength, 3)
        let p = try XCTUnwrap(buffer.int16ChannelData?[0])
        XCTAssertEqual([p[0], p[1], p[2]], [1, 32767, -32768])
    }

    func testPcm16BufferRejectsEmptyOrOddInput() {
        XCTAssertNil(EngineMapping.pcm16Buffer(Data(), sampleRate: 16_000))
        XCTAssertNil(EngineMapping.pcm16Buffer(Data([0x01]), sampleRate: 16_000))
        XCTAssertNil(EngineMapping.pcm16Buffer(Data([0x01, 0x00]), sampleRate: 0))
    }

    func testLanguageCodeOfLocaleIdentifiers() {
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "en_US")), "en")
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "vi-VN")), "vi")
        XCTAssertEqual(EngineMapping.languageCode(Locale(identifier: "ja")), "ja")
    }

    func testErrorCodesAreTheEngineErrorNames() {
        XCTAssertEqual(EngineErrors.translateFailed("x").code, "translateFailed")
        XCTAssertEqual(EngineErrors.notReady("x").code, "notReady")
        XCTAssertEqual(EngineErrors.downloadFailed("x").code, "downloadFailed")
        XCTAssertEqual(EngineErrors.notReady("why").message, "why")
    }

    func testEventsFromAnyThreadArriveInOrderOnTheMainThread() {
        let done = expectation(description: "delivered")
        var seen: [String] = []
        var allMain = true
        let queue = EventQueue { event in
            allMain = allMain && Thread.isMainThread
            switch event {
            case .gate(let open): seen.append("gate \(open)")
            case .ttsStart(let id): seen.append("start \(id)")
            case .ttsEnd(let id):
                seen.append("end \(id)")
                if id == 99 { done.fulfill() }
            default: seen.append("other")
            }
        }
        DispatchQueue.global().async {
            queue.send(.gate(true))
            for i in 0..<50 { queue.send(.ttsStart(Int64(i))) }
            queue.send(.gate(false))
            queue.send(.ttsEnd(99))
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(allMain)
        XCTAssertEqual(seen, ["gate true"] + (0..<50).map { "start \($0)" } + ["gate false", "end 99"])
    }
}
