import Foundation
import Observation

// What the conversation screen shows besides the conversation itself.
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
        case .online: Copy.t("chip.online")
        case .phoneMic: Copy.t("chip.phoneMic")
        case .noBoard: Copy.t("chip.noBoard")
        }
    }

    var accessibilityText: String {
        switch self {
        case .online: Copy.t("chip.online.a11y")
        case .phoneMic: Copy.t("chip.phoneMic.a11y")
        case .noBoard: Copy.t("chip.noBoard.a11y")
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

/// Which screen the session state asks for (the readiness view).
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
        case .speechModel: Copy.t("missing.speechModel")
        case .translation: Copy.t("missing.translation", ["from": name(m.from ?? m.language, names), "to": name(m.to, names)])
        case .ttsVoice: Copy.t("missing.ttsVoice")
        }
    }

    static var choose: String { Copy.t("readiness.choose") }
    static var unavailable: String { Copy.t("readiness.unavailable") }
    static var needsDownloadTitle: String { Copy.t("readiness.needsDownloadTitle") }
    static var needsDownloadNote: String { Copy.t("readiness.needsDownloadNote") }
    static var downloadFailed: String { Copy.t("readiness.downloadFailed") }
    static var failedTitle: String { Copy.t("failed.title") }

    static func button(failed: Bool) -> String { Copy.t(failed ? "readiness.retry" : "readiness.download") }

    static func progress(_ p: Double?) -> String {
        guard let p else { return Copy.t("readiness.downloading") }
        return Copy.t("readiness.downloadingPercent", ["percent": String(Int((min(max(p, 0), 1) * 100).rounded()))])
    }

    /// The reason shown under "Không khởi động được"; the machine's own reason for a dead recognizer is English.
    static func failureReason(_ reason: String) -> String {
        reason == "recognizer stopped" ? Copy.t("failed.recognizerStopped") : reason
    }
}

/// The footer of the language list: why a language is missing, and the online opt-in.
enum LanguageFooterText {
    static var optInTitle: String { Copy.t("language.optInTitle") }
    static var optInNote: String { Copy.t("language.optInNote") }

    /// nil when every language is offered.
    static func why(missing: [LanguagePack]) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.label).joined(separator: ", ")
        return Copy.t("language.why", ["names": names])
    }
}

/// Thrown by the glossary closures when a term is rejected; `message` is shown under the field.
struct GlossaryValidationError: Error, Equatable {
    let message: String
}

/// The Vietnamese glossary validation messages.
enum GlossaryMessages {
    static var empty: String { Copy.t("glossary.error.empty") }
    static var tooLong: String { Copy.t("glossary.error.tooLong") }
    static var tooMany: String { Copy.t("glossary.error.tooMany") }
    static var badCharacters: String { Copy.t("glossary.error.badCharacters") }
    static var duplicate: String { Copy.t("glossary.error.duplicate") }
    static var tooManyVariants: String { Copy.t("glossary.error.tooManyVariants") }

    /// The message for a glossary store rejection by its error name (`EmptyText`, `TooLong`, `TooManyVariants`,
    /// `TooManyTerms`, `ForbiddenCharacter`, `DuplicateTerm`); nil for the ones the user cannot cause (`UnknownTerm`).
    static func forErrorName(_ name: String) -> String? {
        switch name {
        case "EmptyText": empty
        case "TooLong": tooLong
        case "TooManyVariants": tooManyVariants
        case "TooManyTerms": tooMany
        case "ForbiddenCharacter": badCharacters
        case "DuplicateTerm": duplicate
        default: nil
        }
    }
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
    /// A change the glossary store refused or could not save after the closure returned ("Không lưu được"); cleared
    /// by the next change.
    var glossaryError: String?

    // MARK: Intents (the controller binds them; the defaults do nothing)

    var pickLanguage: (String) -> Void = { _ in }
    var setOnlineAllowed: (String, Bool) -> Void = { _, _ in }
    var download: () -> Void = {}
    var retry: () -> Void = {}
    var startStop: () -> Void = {}
    var toggleBoardMic: () -> Void = {}
    var clear: () -> Void = {}
    var openTtsSettings: () -> Void = {}
    /// Forget the pinned board and look for one again ("Quên board"); the composition root binds it to the link.
    var forgetBoard: () -> Void = {}
    /// The glossary closures may throw `GlossaryValidationError`.
    var glossaryAdd: (String) throws -> Void = { _ in }
    var glossaryUpdate: (String, String) throws -> Void = { _, _ in }
    var glossaryDelete: (String) throws -> Void = { _ in }

    init() {}

    // MARK: Derived

    var hasHistory: Bool { !lines.isEmpty }

    /// Empty while the engine drives the screen (`session == nil`): the status line already says it.
    var chips: [StatusChip] {
        guard session != nil else { return [] }
        return StatusChip.visible(online: online, micRoute: micRoute, listening: listening, board: board)
    }

    var readiness: ReadinessKind { session.map(ReadinessKind.of) ?? .none }
}
