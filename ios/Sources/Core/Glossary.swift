import Foundation

// Port of app/lib/core/glossary.dart; contract: shared/fixtures/glossary.json (validation and load cases).

/// Why a glossary change was refused or failed. Each case names the offending field (`text`, `variants[2]`,
/// `fixed.en`, or `fixed` for an empty language code) where it has one.
enum GlossaryError: Error, Equatable, Sendable {
    /// A term, variant or fixed translation is empty or only blanks.
    case emptyText(field: String)
    /// A string is longer than `limit` grapheme clusters (Swift `Character`s, as Dart `characters`).
    case tooLong(field: String, limit: Int)
    /// A term has more than `limit` variants.
    case tooManyVariants(limit: Int)
    /// The glossary already holds `limit` terms.
    case tooManyTerms(limit: Int)
    /// A string holds a control character or a bidirectional override.
    case forbiddenCharacter(field: String, codePoint: Int)
    /// `value` is already a term or variant (ignoring case) of another entry.
    case duplicateTerm(field: String, value: String)
    /// No term has this id.
    case unknownTerm(id: String)
    /// The glossary file could not be written; nothing was changed.
    case writeFailed(String)
    /// The store opened read-only: its file could not be read nor set aside, so nothing may overwrite it.
    case readOnly
}

/// The user's glossary (R11): a JSON list of `Term` (the pack term format) in one file, on the phone only (R17).
/// Limits: 500 terms, 64 characters per term (and per variant and fixed translation), 8 variants; control characters
/// and bidirectional overrides (U+202A–U+202E, U+2066–U+2069) are rejected, and every term or variant is unique
/// ignoring case.
///
/// A file that cannot be read back (bad content, or a read error such as permissions or file protection) is renamed
/// to `glossary.corrupt-<yyyyMMdd-HHmmss>.json` beside it and the store starts empty (`recoveredFromCorruption`). If
/// even the rename fails the store opens read-only (`isReadOnly`: every change throws `readOnly`), so the user's data
/// is never overwritten. Changes run one at a time (actor) and are announced on `changes()` until `close()`.
actor GlossaryStore {
    static let maxTerms = 500
    static let maxLength = 64
    static let maxVariants = 8
    static let fileName = "glossary.json"

    /// Application Support, where the app keeps the glossary.
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: false)
    }

    private let file: URL
    private let newId: @Sendable () -> String
    private let broadcast = Broadcast<[Term]>()

    /// The terms, in the order they were added.
    private(set) var terms: [Term]
    /// True when the file was unreadable when the store opened (set aside, or left alone when `isReadOnly`).
    let recoveredFromCorruption: Bool
    /// True when an unreadable file could not be set aside: changes are refused so it is never overwritten.
    let isReadOnly: Bool

    /// Opens `directory/glossary.json` (neither need exist yet; the directory is created on the first change).
    /// `clock` (names a corrupt file set aside) and `newId` are injectable for tests.
    init(directory: URL, clock: () -> Date = { Date() },
         newId: @escaping @Sendable () -> String = { GlossaryStore.randomId() }) {
        file = directory.appendingPathComponent(Self.fileName)
        self.newId = newId
        (terms, recoveredFromCorruption, isReadOnly) = Self.load(file, clock: clock)
    }

    deinit {
        broadcast.finish()
    }

    /// Ends every `changes()` stream, current and future.
    func close() {
        broadcast.finish()
    }

    /// The new list after every successful change, from now on. Subscribes synchronously (call it before the change
    /// you want to see).
    nonisolated func changes() -> AsyncStream<[Term]> {
        broadcast.stream()
    }

    /// Adds a term (always `TermOrigin.user`) and returns it with its id.
    @discardableResult
    func add(text: String, variants: [String] = [], fixed: [String: String] = [:]) throws(GlossaryError) -> Term {
        if isReadOnly { throw .readOnly }
        let term = try Self.validate(id: newId(), text: text, variants: variants, fixed: fixed, among: terms,
                                     ignoring: nil)
        try commit(terms + [term])
        return term
    }

    /// Replaces the term `id`.
    @discardableResult
    func update(_ id: String, text: String, variants: [String] = [],
                fixed: [String: String] = [:]) throws(GlossaryError) -> Term {
        if isReadOnly { throw .readOnly }
        guard let index = terms.firstIndex(where: { $0.id == id }) else { throw .unknownTerm(id: id) }
        let term = try Self.validate(id: id, text: text, variants: variants, fixed: fixed, among: terms, ignoring: id)
        var next = terms
        next[index] = term
        try commit(next)
        return term
    }

    /// Deletes the term `id`.
    func remove(_ id: String) throws(GlossaryError) {
        if isReadOnly { throw .readOnly }
        guard terms.contains(where: { $0.id == id }) else { throw .unknownTerm(id: id) }
        try commit(terms.filter { $0.id != id })
    }

    // MARK: Internals

    /// The checks of `add` (`ignoring` nil: the term count limit applies) and `update` (`ignoring` the id being
    /// replaced) against `terms`, without saving: the cleaned term, or the first rule it breaks. Pure, so the UI can
    /// run it synchronously before handing the change to the store.
    static func validate(id: String, text: String, variants: [String] = [], fixed: [String: String] = [:],
                         among terms: [Term], ignoring: String?) throws(GlossaryError) -> Term {
        if ignoring == nil && terms.count >= maxTerms { throw .tooManyTerms(limit: maxTerms) }
        let cleanText = try check("text", text)
        if variants.count > maxVariants { throw .tooManyVariants(limit: maxVariants) }
        var cleanVariants: [String] = []
        for (i, v) in variants.enumerated() {
            cleanVariants.append(try check("variants[\(i)]", v))
        }
        var cleanFixed: [String: String] = [:]
        for (rawCode, value) in fixed.sorted(by: { $0.key < $1.key }) {
            let code = rawCode.dartTrimmed
            if code.isEmpty { throw .emptyText(field: "fixed") }
            cleanFixed[code] = try check("fixed.\(code)", value)
        }

        var taken = Set<String>()
        for t in terms where t.id != ignoring {
            for s in [t.text] + t.variants { taken.insert(key(s)) }
        }
        for (i, s) in ([cleanText] + cleanVariants).enumerated() where !taken.insert(key(s)).inserted {
            throw .duplicateTerm(field: i == 0 ? "text" : "variants[\(i - 1)]", value: s)
        }
        return Term(id: id, text: cleanText, variants: cleanVariants, fixed: cleanFixed, origin: .user)
    }

    /// Uniqueness key: NFC, lower case.
    private static func key(_ s: String) -> String { s.nfc.lowercased() }

    /// Trims `value` and applies the per-string rules.
    private static func check(_ field: String, _ value: String) throws(GlossaryError) -> String {
        let s = value.dartTrimmed
        if s.isEmpty { throw .emptyText(field: field) }
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069:
                throw .forbiddenCharacter(field: field, codePoint: Int(scalar.value))
            default: break
            }
        }
        if s.count > maxLength { throw .tooLong(field: field, limit: maxLength) }
        return s
    }

    private func commit(_ next: [Term]) throws(GlossaryError) {
        if isReadOnly { throw .readOnly }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(next).write(to: file, options: .atomic)
        } catch {
            throw .writeFailed(String(describing: error))
        }
        terms = next
        broadcast.send(next)
    }

    /// Reads the file: the terms, whether it was unreadable, and whether the store must stay read-only. Only an
    /// absent file is an empty glossary; any read error is treated like corruption. A hand-edited file must not get
    /// around the limits: any bad entry, an entry over the limits, duplicate texts or duplicate ids set it aside.
    private static func load(_ file: URL, clock: () -> Date) -> ([Term], Bool, Bool) {
        if !FileManager.default.fileExists(atPath: file.path) { return ([], false, false) }  // not there yet
        do {
            let loaded = try JSONDecoder().decode([Term].self, from: Data(contentsOf: file))
            if loaded.count > maxTerms { throw GlossaryError.tooManyTerms(limit: maxTerms) }
            var seen = Set<String>()
            var ids = Set<String>()
            for t in loaded {
                if !ids.insert(t.id).inserted { throw GlossaryError.duplicateTerm(field: "id", value: t.id) }
                _ = try check("text", t.text)
                if t.variants.count > maxVariants { throw GlossaryError.tooManyVariants(limit: maxVariants) }
                for v in t.variants { _ = try check("variants", v) }
                for v in t.fixed.values { _ = try check("fixed", v) }
                for s in [t.text] + t.variants where !seen.insert(key(s)).inserted {
                    throw GlossaryError.duplicateTerm(field: "text", value: s)
                }
            }
            return (loaded, false, false)
        } catch {
            return ([], true, !setAside(file, now: clock()))
        }
    }

    /// Renames a corrupt file to `glossary.corrupt-<yyyyMMdd-HHmmss>[-n].json` (local time) beside it. False when
    /// the rename failed.
    private static func setAside(_ file: URL, now: Date) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let stamp = String(format: "%04d", c.year ?? 0) + two(c.month) + two(c.day) + "-" + two(c.hour)
            + two(c.minute) + two(c.second)
        let directory = file.deletingLastPathComponent()
        var target = directory.appendingPathComponent("glossary.corrupt-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("glossary.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
            return true
        } catch {
            return false
        }
    }

    static func randomId() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}
