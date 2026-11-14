import Foundation

// Language packs, board font sets, engine capabilities, board info.
// Packs are Codable from shared/languages/*.json.

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
        id = try c.packString(.id, path)
        pattern = try c.packString(.pattern, path)
        template = try c.packString(.template, path)
        atClauseStart = try c.packOptional(Bool.self, .atClauseStart, path, dartType: "bool") ?? false
        context = try c.packOptional(String.self, .context, path, dartType: "String")
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
        // Same check order as Dart `Term.fromJson`: origin, fixed (a map), id, text, variants, fixed entries.
        let path = packPath(decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try c.packOptional(String.self, .origin, path, dartType: "String") {
            guard let origin = TermOrigin(rawValue: name) else {
                throw PackError(field: joinPath(path, "origin"), reason: "unknown origin \"\(name)\"")
            }
            self.origin = origin
        } else {
            origin = .user
        }
        let fixedMap = try c.packMap(.fixed, path)
        id = try c.packString(.id, path)
        text = try c.packString(.text, path)
        variants = try c.packStringList(.variants, path)
        var fixed: [String: String] = [:]
        if let fixedMap {
            for key in fixedMap.allKeys {
                guard let value = try? fixedMap.decode(String.self, forKey: key) else {
                    throw PackError(field: joinPath(path, "fixed"), reason: "values must be strings")
                }
                fixed[key.stringValue] = value
            }
        }
        self.fixed = fixed
    }
}

/// One language: Apple locale, board label, script, their-side confidence gate, rules, terms, hints.
struct LanguagePack: Codable, Hashable, Sendable {
    var code: String
    var appleLocale: String
    var label: String
    var labelLatin: String
    var script: Script
    var minConfidence: Double?
    var recognition: [Rule] = []
    var beforeTranslation: [Rule] = []
    var terms: [Term] = []
    var hints: [String] = []

    init(code: String, appleLocale: String, label: String,
         labelLatin: String, script: Script, minConfidence: Double? = nil, recognition: [Rule] = [],
         beforeTranslation: [Rule] = [], terms: [Term] = [], hints: [String] = []) {
        self.code = code
        self.appleLocale = appleLocale
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
        // Same check order as Dart `LanguagePack.fromJson`.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scriptName = try c.packString(.script, "")
        guard let script = Script(rawValue: scriptName) else {
            throw PackError(field: "script", reason: "unknown script \"\(scriptName)\"")
        }
        self.script = script
        minConfidence = try c.packOptional(Double.self, .minConfidence, "", dartType: "num")
        code = try c.packString(.code, "")
        appleLocale = try c.packString(.appleLocale, "")
        label = try c.packString(.label, "")
        labelLatin = try c.packString(.labelLatin, "")
        recognition = try c.packObjectList(Rule.self, .recognition)
        beforeTranslation = try c.packObjectList(Rule.self, .beforeTranslation)
        terms = try c.packObjectList(Term.self, .terms)
        hints = try c.packStringList(.hints, "")
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

/// Any string key, for walking a JSON object of unknown keys (`Term.fixed`).
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Ports of the Dart helpers `_str`, `_opt<T>`, `_strList`, `_objList`: same field paths and reasons.
private extension KeyedDecodingContainer {
    func isAbsent(_ key: Key) throws -> Bool {
        try !contains(key) || decodeNil(forKey: key)
    }

    /// Dart `_str`: a required string.
    func packString(_ key: Key, _ path: String) throws -> String {
        let field = joinPath(path, key.stringValue)
        if try isAbsent(key) { throw PackError(field: field, reason: "missing") }
        guard let value = try? decode(String.self, forKey: key) else {
            throw PackError(field: field, reason: "must be a string")
        }
        return value
    }

    /// Dart `_opt<T>`: absent or null → nil. `dartType` is how Dart prints `T`, for the same reason text.
    func packOptional<T: Decodable>(_ type: T.Type, _ key: Key, _ path: String, dartType: String) throws -> T? {
        if try isAbsent(key) { return nil }
        guard let value = try? decode(T.self, forKey: key) else {
            throw PackError(field: joinPath(path, key.stringValue), reason: "must be a \(dartType)")
        }
        return value
    }

    /// Dart `_opt<Map>`.
    func packMap(_ key: Key, _ path: String) throws -> KeyedDecodingContainer<AnyKey>? {
        if try isAbsent(key) { return nil }
        guard let map = try? nestedContainer(keyedBy: AnyKey.self, forKey: key) else {
            throw PackError(field: joinPath(path, key.stringValue), reason: "must be a Map<dynamic, dynamic>")
        }
        return map
    }

    /// Dart `_opt<List>`.
    func packList(_ key: Key, _ path: String) throws -> UnkeyedDecodingContainer? {
        if try isAbsent(key) { return nil }
        guard let list = try? nestedUnkeyedContainer(forKey: key) else {
            throw PackError(field: joinPath(path, key.stringValue), reason: "must be a List<dynamic>")
        }
        return list
    }

    /// Dart `_strList`: a bad entry reports the list's path, not the entry's.
    func packStringList(_ key: Key, _ path: String) throws -> [String] {
        guard var list = try packList(key, path) else { return [] }
        var out: [String] = []
        while !list.isAtEnd {
            guard let s = try? list.decode(String.self) else {
                throw PackError(field: joinPath(path, key.stringValue), reason: "entries must be strings")
            }
            out.append(s)
        }
        return out
    }

    /// Dart `_objList` (top-level keys only): a non-object entry is `key[i]`, "must be an object". Errors inside an
    /// entry are already `PackError`s (its fields are read with the helpers above).
    func packObjectList<T: Decodable>(_ type: T.Type, _ key: Key) throws -> [T] {
        guard var list = try packList(key, "") else { return [] }
        var out: [T] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            do {
                out.append(try list.decode(T.self))
            } catch is DecodingError {
                throw PackError(field: "\(key.stringValue)[\(index)]", reason: "must be an object")
            }
        }
        return out
    }
}

private extension PackError {
    /// What is left for JSONDecoder itself to report: invalid JSON, or a document that is not an object.
    init(decoding error: DecodingError) {
        switch error {
        case let .dataCorrupted(context) where context.codingPath.isEmpty:
            self.init(field: "", reason: "invalid JSON: \(context.debugDescription)")
        case let .typeMismatch(_, context) where context.codingPath.isEmpty:
            self.init(field: "", reason: "pack must be a JSON object")
        default:
            self.init(field: "", reason: "\(error)")
        }
    }
}
