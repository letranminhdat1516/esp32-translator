import Foundation

// Port of app/lib/core/model.dart: language packs, board font sets, engine capabilities, board info.
// Packs are Codable from the same JSON the Dart and TypeScript apps load (app/assets/languages, later shared/languages).

/// Writing system a language is displayed in; decides which board font set is needed (`FontSets.covers`).
enum Script: String, Codable, CaseIterable, Sendable {
    case latin, cjk, hangul, thai, cyrillic, other
}

/// Thrown by `LanguagePack.parse` when a pack is malformed. `field` is the path of the offending field,
/// e.g. `label` or `recognition[0].pattern`; empty for the whole document.
struct PackError: Error, Equatable, CustomStringConvertible {
    let field: String
    let reason: String

    var description: String { "PackError(\(field)): \(reason)" }
}

/// Bit mask of the glyph sets the board firmware has fonts for (the BLE `fontSets` u32).
struct FontSets: OptionSet, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Bit 1: Basic Latin plus the Vietnamese letters and tone marks.
    static let latinVI = FontSets(rawValue: 1)
    /// Bit 2: Latin Extended-A, U+0100-U+017F, in addition to `latinVI`.
    static let latinExtA = FontSets(rawValue: 2)
    /// Bit 4: CJK ideographs plus Japanese kana.
    static let cjk = FontSets(rawValue: 4)
    /// Bit 8: Korean Hangul syllables.
    static let hangul = FontSets(rawValue: 8)
    /// Bit 16: Thai.
    static let thai = FontSets(rawValue: 16)

    /// The raw bitmask (Dart `value`).
    var value: Int { Int(rawValue) }

    static func | (lhs: FontSets, rhs: FontSets) -> FontSets { lhs.union(rhs) }

    // `contains(_:)` comes from OptionSet: true when every bit of the argument is set.

    /// True when the board can render text written in `script`. Cyrillic and other scripts have no board font.
    func covers(_ script: Script) -> Bool {
        switch script {
        case .latin: contains(.latinVI) || contains(.latinExtA)
        case .cjk: contains(.cjk)
        case .hangul: contains(.hangul)
        case .thai: contains(.thai)
        case .cyrillic, .other: false
        }
    }

    var description: String { "FontSets(\(rawValue))" }
}

/// A data-driven text rule of a language pack (applied by the rule engine, Phase 1).
struct Rule: Codable, Hashable, Sendable {
    var id: String
    var pattern: String
    var template: String
    var atClauseStart: Bool = false
    var context: String?

    init(id: String, pattern: String, template: String, atClauseStart: Bool = false, context: String? = nil) {
        self.id = id
        self.pattern = pattern
        self.template = template
        self.atClauseStart = atClauseStart
        self.context = context
    }

    init(from decoder: Decoder) throws {
        let path = packPath(decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pattern = try c.decode(String.self, forKey: .pattern)
        template = try c.decode(String.self, forKey: .template)
        atClauseStart = try c.decodeIfPresent(Bool.self, forKey: .atClauseStart) ?? false
        context = try c.decodeIfPresent(String.self, forKey: .context)
        try checkRegex(pattern, field: joinPath(path, "pattern"))
        if let context { try checkRegex(context, field: joinPath(path, "context")) }
    }
}

enum TermOrigin: String, Codable, CaseIterable, Sendable {
    case builtIn, user
}

/// A protected name or term: matched in `text` or any of its `variants`, translated as `fixed[target]` when given.
struct Term: Codable, Hashable, Sendable {
    var id: String
    var text: String
    var variants: [String] = []
    /// Fixed translation per target language code.
    var fixed: [String: String] = [:]
    var origin: TermOrigin = .user

    init(id: String, text: String, variants: [String] = [], fixed: [String: String] = [:], origin: TermOrigin = .user) {
        self.id = id
        self.text = text
        self.variants = variants
        self.fixed = fixed
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let path = packPath(decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        fixed = try c.decodeIfPresent([String: String].self, forKey: .fixed) ?? [:]
        if let name = try c.decodeIfPresent(String.self, forKey: .origin) {
            guard let origin = TermOrigin(rawValue: name) else {
                throw PackError(field: joinPath(path, "origin"), reason: "unknown origin \"\(name)\"")
            }
            self.origin = origin
        } else {
            origin = .user
        }
    }
}

/// One language: locales per engine, board label, script, their-side confidence gate, rules, terms, hints.
struct LanguagePack: Codable, Hashable, Sendable {
    var code: String
    var appleLocale: String
    var androidLocale: String
    var whisperCode: String
    var label: String
    var labelLatin: String
    var script: Script
    var minConfidence: Double?
    var recognition: [Rule] = []
    var beforeTranslation: [Rule] = []
    var terms: [Term] = []
    var hints: [String] = []

    init(code: String, appleLocale: String, androidLocale: String, whisperCode: String, label: String,
         labelLatin: String, script: Script, minConfidence: Double? = nil, recognition: [Rule] = [],
         beforeTranslation: [Rule] = [], terms: [Term] = [], hints: [String] = []) {
        self.code = code
        self.appleLocale = appleLocale
        self.androidLocale = androidLocale
        self.whisperCode = whisperCode
        self.label = label
        self.labelLatin = labelLatin
        self.script = script
        self.minConfidence = minConfidence
        self.recognition = recognition
        self.beforeTranslation = beforeTranslation
        self.terms = terms
        self.hints = hints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scriptName = try c.decode(String.self, forKey: .script)
        guard let script = Script(rawValue: scriptName) else {
            throw PackError(field: "script", reason: "unknown script \"\(scriptName)\"")
        }
        self.script = script
        code = try c.decode(String.self, forKey: .code)
        appleLocale = try c.decode(String.self, forKey: .appleLocale)
        androidLocale = try c.decode(String.self, forKey: .androidLocale)
        whisperCode = try c.decode(String.self, forKey: .whisperCode)
        label = try c.decode(String.self, forKey: .label)
        labelLatin = try c.decode(String.self, forKey: .labelLatin)
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence)
        recognition = try c.decodeIfPresent([Rule].self, forKey: .recognition) ?? []
        beforeTranslation = try c.decodeIfPresent([Rule].self, forKey: .beforeTranslation) ?? []
        terms = try c.decodeIfPresent([Term].self, forKey: .terms) ?? []
        hints = try c.decodeIfPresent([String].self, forKey: .hints) ?? []
    }

    /// Parses and validates pack JSON. Throws `PackError` on invalid JSON, a missing or mistyped field, an unknown
    /// script or origin, or a regex that does not compile.
    static func parse(_ json: String) throws -> LanguagePack {
        try parse(Data(json.utf8))
    }

    static func parse(_ data: Data) throws -> LanguagePack {
        do {
            return try JSONDecoder().decode(LanguagePack.self, from: data)
        } catch let error as DecodingError {
            throw PackError(decoding: error)
        }
    }

    /// The pack as JSON (Dart `toJson`); `parse` of the result gives an equal pack.
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

enum RecognizerKind: String, Codable, CaseIterable, Sendable {
    case osOnDevice, whisper, osOnline
}

/// What the device can do, from the native engine.
struct Capabilities: Hashable, Sendable {
    /// Recognizers available (or downloadable) per language code, best first.
    var recognizers: [String: [RecognizerKind]]
    /// Language codes the device can translate to or from.
    var translatable: Set<String>
    var vietnameseVoice: Bool
}

/// What the board reports on `…0005`.
struct BoardInfo: Hashable, Sendable {
    var protocolVersion: Int
    var fontSets: FontSets
}

// MARK: - JSON helpers

/// Dart-style path of a coding path: `recognition[0].pattern`.
private func packPath(_ codingPath: [CodingKey]) -> String {
    codingPath.reduce(into: "") { path, key in
        if let index = key.intValue {
            path += "[\(index)]"
        } else {
            path = joinPath(path, key.stringValue)
        }
    }
}

private func joinPath(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : "\(path).\(key)"
}

private func checkRegex(_ pattern: String, field: String) throws {
    do {
        _ = try NSRegularExpression(pattern: pattern)
    } catch {
        throw PackError(field: field, reason: "invalid regex: \(error.localizedDescription)")
    }
}

private extension PackError {
    init(decoding error: DecodingError) {
        switch error {
        case let .keyNotFound(key, context):
            self.init(field: packPath(context.codingPath + [key]), reason: "missing")
        case let .valueNotFound(_, context):
            self.init(field: packPath(context.codingPath), reason: "missing")
        case let .typeMismatch(type, context):
            let field = packPath(context.codingPath)
            if field.isEmpty {
                self.init(field: "", reason: "pack must be a JSON object")
            } else if type is [String: Any].Type {
                self.init(field: field, reason: "must be an object")
            } else {
                self.init(field: field, reason: "must be a \(type)")
            }
        case let .dataCorrupted(context):
            if context.codingPath.isEmpty {
                self.init(field: "", reason: "invalid JSON: \(context.debugDescription)")
            } else {
                self.init(field: packPath(context.codingPath), reason: context.debugDescription)
            }
        @unknown default:
            self.init(field: "", reason: "\(error)")
        }
    }
}
