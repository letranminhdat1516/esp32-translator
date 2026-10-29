import XCTest
@testable import TranslatorCore

final class UIStateTests: XCTestCase {
    func testChipsOnlineShowsAlways() {
        XCTAssertEqual(StatusChip.visible(online: true, micRoute: .headset, listening: false, board: .ready), [.online])
    }

    func testPhoneMicChipOnlyWhileListening() {
        XCTAssertEqual(StatusChip.visible(online: false, micRoute: .phoneMic, listening: false, board: .ready), [])
        XCTAssertEqual(StatusChip.visible(online: false, micRoute: .phoneMic, listening: true, board: .ready), [.phoneMic])
    }

    func testNoBoardChipOnlyWhileListeningWithoutReadyBoard() {
        for board in [BoardState.off, .scanning, .connecting] {
            XCTAssertEqual(StatusChip.visible(online: false, micRoute: .headset, listening: true, board: board), [.noBoard])
            XCTAssertEqual(StatusChip.visible(online: false, micRoute: .headset, listening: false, board: board), [])
        }
        XCTAssertEqual(StatusChip.visible(online: false, micRoute: .headset, listening: true, board: .ready), [])
    }

    func testChipOrderAndTexts() {
        let all = StatusChip.visible(online: true, micRoute: .phoneMic, listening: true, board: .off)
        XCTAssertEqual(all.map(\.text), ["online", "mic điện thoại", "không có board"])
    }

    func testReadinessKindPerState() {
        XCTAssertEqual(ReadinessKind.of(.loading), .spinner)
        XCTAssertEqual(ReadinessKind.of(.choosing()), .choosing)
        XCTAssertEqual(ReadinessKind.of(.checking("en")), .spinner)
        XCTAssertEqual(ReadinessKind.of(.needsDownload("en", missing: [])), .needsDownload)
        XCTAssertEqual(ReadinessKind.of(.downloading("en")), .downloading)
        XCTAssertEqual(ReadinessKind.of(.preparing("en")), .spinner)
        XCTAssertEqual(ReadinessKind.of(.running("en")), .none)
        XCTAssertEqual(ReadinessKind.of(.switching(from: "en", to: "ja")), .spinner)
        XCTAssertEqual(ReadinessKind.of(.failed("en", reason: "x")), .failed)
    }

    func testMissingTexts() {
        let names = ["vi": "Tiếng Việt", "en": "English"]
        XCTAssertEqual(ReadinessText.missing(MissingMsg(kind: .speechModel, language: "en"), names: names),
                       "Mô hình nhận giọng")
        XCTAssertEqual(ReadinessText.missing(MissingMsg(kind: .ttsVoice, language: "vi"), names: names),
                       "Giọng đọc tiếng Việt")
        XCTAssertEqual(ReadinessText.missing(MissingMsg(kind: .translation, language: "en", from: "en", to: "vi"),
                                             names: names), "Bản dịch English → Tiếng Việt")
        // A code without a name is shown as is; `from` falls back to `language`
        XCTAssertEqual(ReadinessText.missing(MissingMsg(kind: .translation, language: "ja", to: "vi"), names: [:]),
                       "Bản dịch ja → vi")
    }

    func testProgressText() {
        XCTAssertEqual(ReadinessText.progress(nil), "Đang tải…")
        XCTAssertEqual(ReadinessText.progress(0.426), "Đang tải… 43%")
        XCTAssertEqual(ReadinessText.progress(1.4), "Đang tải… 100%")
        XCTAssertEqual(ReadinessText.button(failed: false), "Tải về")
        XCTAssertEqual(ReadinessText.button(failed: true), "Thử lại")
    }

    func testFailureReasonAndSpinnerText() {
        XCTAssertEqual(ReadinessText.failureReason("recognizer stopped"), "Bộ nhận giọng đã dừng.")
        XCTAssertEqual(ReadinessText.failureReason("mic busy"), "mic busy")
        XCTAssertEqual(ReadinessText.spinner(.switching(from: "en", to: "ja"), names: ["ja": "日本語"]),
                       "Đang chuyển sang 日本語…")
        XCTAssertNil(ReadinessText.spinner(.loading, names: [:]))
    }

    func testFooterText() {
        XCTAssertNil(LanguageFooterText.why(missing: []))
        let fr = LanguagePack(code: "fr", appleLocale: "fr-FR", androidLocale: "fr-FR", whisperCode: "fr",
                              label: "Français", labelLatin: "Français", script: .latin)
        XCTAssertTrue(LanguageFooterText.why(missing: [fr])?.contains("Français") == true)
    }

    func testGlossaryMessages() {
        XCTAssertEqual(GlossaryMessages.empty, "Từ không được để trống")
        XCTAssertEqual(GlossaryMessages.tooLong, "Tối đa 64 ký tự")
        XCTAssertEqual(GlossaryMessages.tooMany, "Tối đa 500 từ")
        XCTAssertEqual(GlossaryMessages.badCharacters, "Có ký tự không hợp lệ")
    }

    @MainActor
    func testDefaultsKeepTheLegacyScreen() {
        let ui = UIState()
        XCTAssertNil(ui.session)
        XCTAssertEqual(ui.readiness, .none)
        XCTAssertEqual(ui.chips, [])
        XCTAssertFalse(ui.hasHistory)
        XCTAssertEqual(ui.languageLabel, "English")
    }

    @MainActor
    func testIntentsAreBoundByTheController() throws {
        let ui = UIState()
        var picked: String?
        ui.pickLanguage = { picked = $0 }
        ui.pickLanguage("ja")
        XCTAssertEqual(picked, "ja")
        ui.glossaryAdd = { _ in throw GlossaryValidationError(message: GlossaryMessages.empty) }
        XCTAssertThrowsError(try ui.glossaryAdd("")) {
            XCTAssertEqual($0 as? GlossaryValidationError, GlossaryValidationError(message: "Từ không được để trống"))
        }
        ui.session = .needsDownload("en", missing: [])
        XCTAssertEqual(ui.readiness, .needsDownload)
    }
}
