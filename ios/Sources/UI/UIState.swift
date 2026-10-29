import Foundation
import Observation

// What the conversation screen shows besides the conversation itself: port of app/lib/ui/conversation_state.dart.
// Pure data plus intents as closures: the views read this and call the closures, and P2.2's controller fills it
// without touching a view. With the defaults (`session == nil`) the views show what the engine drives today.

/// One line of the conversation (theirs or mine).
struct UILine: Identifiable, Hashable, Sendable {
    var id: String
    var mine: Bool
    var source: String
    var target: String
    /// Recognized with low confidence: the translation is shown faint.
    var unclear = false
    /// When the line was last spoken: orders both sides into one stream.
    var at: Date
}

/// The small marks next to the status line.
enum StatusChip: Hashable, Sendable {
    case online, phoneMic, noBoard

    var text: String {
        switch self {
        case .online: "online"
        case .phoneMic: "mic điện thoại"
        case .noBoard: "không có board"
        }
    }

    var accessibilityText: String {
        switch self {
        case .online: "Đang nhận giọng qua mạng"
        case .phoneMic: "Đang dùng mic điện thoại"
        case .noBoard: "Chưa kết nối board"
        }
    }

    /// `online` while the recognizer sends audio to the network; `phoneMic` only while listening on the phone's own
    /// mic (headset lost); `noBoard` while listening without a connected board (the conversation still works).
    static func visible(online: Bool, micRoute: AudioRoute, listening: Bool, board: BoardState) -> [StatusChip] {
        var chips: [StatusChip] = []
        if online { chips.append(.online) }
        if listening && micRoute == .phoneMic { chips.append(.phoneMic) }
        if listening && board != .ready { chips.append(.noBoard) }
        return chips
    }
}

/// Which screen the session state asks for (the readiness view of the Dart app).
enum ReadinessKind: Hashable, Sendable {
    case choosing, needsDownload, downloading, failed, spinner, none

    static func of(_ state: SessionState) -> ReadinessKind {
        switch state {
        case .choosing: .choosing
        case .needsDownload: .needsDownload
        case .downloading: .downloading
        case .failed: .failed
        case .loading, .checking, .preparing, .switching: .spinner
        case .running: .none
        }
    }
}

/// Vietnamese texts of the readiness view, pure so they can be tested.
enum ReadinessText {
    static func name(_ code: String?, _ names: [String: String]) -> String {
        guard let code else { return "" }
        return names[code] ?? code
    }

    /// The Vietnamese name of one missing item.
    static func missing(_ m: MissingMsg, names: [String: String]) -> String {
        switch m.kind {
        case .speechModel: "Mô hình nhận giọng"
        case .translation: "Bản dịch \(name(m.from ?? m.language, names)) → \(name(m.to, names))"
        case .ttsVoice: "Giọng đọc tiếng Việt"
        }
    }

    static let choose = "Chọn ngôn ngữ"
    static let unavailable = "Ngôn ngữ đã chọn trước đó không còn dùng được trên máy này."
    static let needsDownloadTitle = "Cần tải về trước khi dùng"
    static let needsDownloadNote = "Tải một lần, sau đó dịch hoàn toàn trên máy: không cần mạng và nhanh hơn."
    static let downloadFailed = "Chưa tải xong. Kiểm tra mạng rồi thử lại."
    static let failedTitle = "Không khởi động được"

    static func button(failed: Bool) -> String { failed ? "Thử lại" : "Tải về" }

    static func progress(_ p: Double?) -> String {
        guard let p else { return "Đang tải…" }
        return "Đang tải… \(Int((min(max(p, 0), 1) * 100).rounded()))%"
    }

    /// The reason shown under "Không khởi động được"; the machine's own reason for a dead recognizer is English.
    static func failureReason(_ reason: String) -> String {
        reason == "recognizer stopped" ? "Bộ nhận giọng đã dừng." : reason
    }

    /// Text under the spinner for the transient states.
    static func spinner(_ state: SessionState, names: [String: String]) -> String? {
        switch state {
        case .checking: "Đang kiểm tra…"
        case .preparing: "Đang chuẩn bị…"
        case let .switching(_, to): "Đang chuyển sang \(name(to, names))…"
        default: nil
        }
    }
}

/// The footer of the language list: why a language is missing, and the online opt-in.
enum LanguageFooterText {
    static let optInTitle = "Nhận giọng qua mạng"
    static let optInNote = "Âm thanh được gửi lên máy chủ nhận giọng của hệ thống và ngôn ngữ này sẽ có nhãn \"online\"."

    /// nil when every language is offered.
    static func why(missing: [LanguagePack]) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.label).joined(separator: ", ")
        return "Chưa có: \(names). Máy này chưa nhận giọng ngoại tuyến được các ngôn ngữ này."
    }
}

/// Thrown by the glossary closures when a term is rejected; `message` is shown under the field.
struct GlossaryValidationError: Error, Equatable {
    let message: String
}

/// The Vietnamese glossary validation messages.
enum GlossaryMessages {
    static let empty = "Từ không được để trống"
    static let tooLong = "Tối đa 64 ký tự"
    static let tooMany = "Tối đa 500 từ"
    static let badCharacters = "Có ký tự không hợp lệ"
}

@Observable @MainActor
final class UIState {
    // MARK: Session

    /// nil: the legacy `ConversationEngine` drives the screen (EN ↔ VI). Set by the controller (P2.2).
    var session: SessionState?
    /// The picked language ("en"), nil while choosing.
    var languageCode: String?
    /// The header shows "Tiếng Việt ⇄ <label>".
    var languageLabel = "English"

    // MARK: Languages

    /// Languages listed in the sheet and while choosing.
    var offeredPacks: [LanguagePack] = []
    /// Display name per language code, including the home language: used in "Bản dịch A → B".
    var languageNames: [String: String] = [:]
    /// Offered only through the online recognizer (marked "online" in the list).
    var onlineCodes: Set<String> = []
    /// Not offered, but would work with the online recognizer: the footer lists them with the opt-in.
    var onlineCandidates: [LanguagePack] = []
    /// Languages the user allowed the online recognizer for.
    var onlineAllowed: Set<String> = []
    /// 0...1 while downloading; nil when the platform reports none.
    var downloadProgress: Double?

    // MARK: Conversation

    var lines: [UILine] = []
    var theirPartial = ""
    var myPartial = ""
    var listening = false
    var board: BoardState = .off
    var boardMicOn = true

    // MARK: Chips and banner

    /// The recognizer sends audio to the network.
    var online = false
    /// Where "my" audio comes from.
    var micRoute: AudioRoute = .headset
    /// The Vietnamese voice is missing: banner with a button to the system TTS settings.
    var ttsVoiceMissing = false

    // MARK: Glossary

    var glossaryTerms: [Term] = []

    // MARK: Intents (the controller binds them; the defaults do nothing)

    var pickLanguage: (String) -> Void = { _ in }
    var setOnlineAllowed: (String, Bool) -> Void = { _, _ in }
    var download: () -> Void = {}
    var retry: () -> Void = {}
    var startStop: () -> Void = {}
    var toggleBoardMic: () -> Void = {}
    var clear: () -> Void = {}
    var openTtsSettings: () -> Void = {}
    /// The glossary closures may throw `GlossaryValidationError`.
    var glossaryAdd: (String) throws -> Void = { _ in }
    var glossaryUpdate: (String, String) throws -> Void = { _, _ in }
    var glossaryDelete: (String) throws -> Void = { _ in }

    init() {}

    // MARK: Derived

    var hasHistory: Bool { !lines.isEmpty }

    var chips: [StatusChip] {
        StatusChip.visible(online: online, micRoute: micRoute, listening: listening, board: board)
    }

    var readiness: ReadinessKind { session.map(ReadinessKind.of) ?? .none }
}
