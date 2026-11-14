import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Compiled into the app and the widget extension (the extension does not link the app).

/// What the Live Activity shows; kept small (the latest phrase pair only, well under 4 KB).
struct TranslatorActivityState: Codable, Hashable, Sendable {
    var listening: Bool
    /// Board battery in percent; nil without a board.
    var boardBattery: Int?
    /// Their last phrase in their language ("Can I pay by card at Ben Thanh?").
    var theirs: String
    /// Its Vietnamese translation.
    var translation: String
    /// The board mic is on.
    var micOn: Bool

    init(listening: Bool = true, boardBattery: Int? = nil, theirs: String = "", translation: String = "", micOn: Bool = true) {
        self.listening = listening
        self.boardBattery = boardBattery
        self.theirs = theirs
        self.translation = translation
        self.micOn = micOn
    }

    /// The longest phrase kept in an update (characters), so the payload stays small.
    static let maxPhrase = 280

    /// The state with both phrases cut to `maxPhrase` characters (an ellipsis marks a cut).
    func trimmed() -> TranslatorActivityState {
        func cut(_ s: String) -> String { s.count <= Self.maxPhrase ? s : String(s.prefix(Self.maxPhrase - 1)) + "…" }
        var t = self
        t.theirs = cut(theirs)
        t.translation = cut(translation)
        return t
    }
}

/// The static part: which language is being translated.
struct TranslatorActivityStatic: Codable, Hashable, Sendable {
    /// "en"
    var languageCode: String
    /// The Vietnamese name used in "Đang dịch tiếng Anh" ("tiếng Anh").
    var languageName: String
}

#if canImport(ActivityKit) && os(iOS)
struct TranslatorActivityAttributes: ActivityAttributes {
    typealias ContentState = TranslatorActivityState
    var languageCode: String
    var languageName: String

    init(_ s: TranslatorActivityStatic) {
        languageCode = s.languageCode
        languageName = s.languageName
    }

    var info: TranslatorActivityStatic { TranslatorActivityStatic(languageCode: languageCode, languageName: languageName) }
}
#endif
