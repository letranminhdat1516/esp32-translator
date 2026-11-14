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
    /// And in UTF-8 bytes: a character can take many bytes (combining marks, emoji), so the byte cap keeps the
    /// encoded state well under ActivityKit's 4 KB even for unusual text.
    static let maxPhraseBytes = 900

    /// The state with both phrases cut to `maxPhrase` characters and `maxPhraseBytes` bytes (an ellipsis marks a cut).
    func trimmed() -> TranslatorActivityState {
        func cut(_ s: String) -> String {
            if s.count <= Self.maxPhrase && s.utf8.count <= Self.maxPhraseBytes { return s }
            let ellipsis = "…"
            var out = ""
            var bytes = ellipsis.utf8.count
            for ch in s.prefix(Self.maxPhrase - 1) {
                let n = ch.utf8.count
                if bytes + n > Self.maxPhraseBytes { break }
                out.append(ch)
                bytes += n
            }
            return out + ellipsis
        }
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

    /// "EN" for "en", "ZH" for "zh-Hans": the Dynamic Island's "EN→VI".
    var shortCode: String {
        String(languageCode.split(separator: "-").first ?? Substring(languageCode)).uppercased()
    }

    /// The name in "Đang dịch tiếng Anh" for a language code (primary subtag); `label` for a language the copy
    /// has no name for.
    static func vietnameseName(_ code: String, label: String) -> String {
        switch (code.split(separator: "-").first.map(String.init) ?? code).lowercased() {
        case "en": Copy.t("activity.lang.en")
        case "de": Copy.t("activity.lang.de")
        case "es": Copy.t("activity.lang.es")
        case "fr": Copy.t("activity.lang.fr")
        case "ja": Copy.t("activity.lang.ja")
        case "ko": Copy.t("activity.lang.ko")
        case "th": Copy.t("activity.lang.th")
        case "zh": Copy.t("activity.lang.zh")
        default: label
        }
    }
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
