import Foundation
import Testing
@testable import TranslatorCore

/// Reads the shared test fixtures (`shared/fixtures/*.json`) and the shared data
/// (`shared/languages`, `shared/board_glyphs`) in place from the repository, like `languagesDirectory`.
enum Fixtures {
    static let sharedDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TranslatorCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("shared")

    /// `shared/fixtures/<name>.json` as a JSON object.
    static func load(_ name: String) -> [String: Any] {
        let url = sharedDirectory.appendingPathComponent("fixtures/\(name).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("fixture \(name).json missing or not a JSON object")
        }
        return object
    }

    /// The cases of `group` (a list of objects, each with a unique `name`), for `@Test(arguments:)`. A missing group
    /// is a fixture error, so a typo cannot silently skip cases.
    static func cases(_ name: String, _ group: String) -> [FixtureCase] {
        cases(in: load(name), group, fixture: name)
    }

    static func cases(in object: [String: Any], _ group: String, fixture: String = "?") -> [FixtureCase] {
        guard let list = object[group] as? [[String: Any]] else {
            fatalError("fixture \(fixture): missing \"\(group)\" (keys: \(object.keys.sorted()))")
        }
        return list.map { FixtureCase($0) }
    }

    /// `shared/languages/<code>.json`, parsed.
    static func pack(_ code: String) throws -> LanguagePack {
        try LanguagePack.parse(Data(contentsOf: sharedDirectory.appendingPathComponent("languages/\(code).json")))
    }

    /// An inline pack object of a fixture, parsed with the same parser as the files.
    static func pack(object: [String: Any]) throws -> LanguagePack {
        try LanguagePack.parse(JSONSerialization.data(withJSONObject: object))
    }

    /// `{"pack": code}` / `{"file": code}` or an inline pack object.
    static func packRef(_ object: [String: Any]) throws -> LanguagePack {
        if let code = (object["pack"] ?? object["file"]) as? String { return try pack(code) }
        return try pack(object: object)
    }

    /// A `Term` from the fixture term format (`id` defaults to `text`, `variants` to [], `fixed` to {}, origin user).
    static func term(_ j: [String: Any]) -> Term {
        let text = j["text"] as! String
        return Term(id: (j["id"] as? String) ?? text, text: text, variants: strings(j["variants"]),
                    fixed: stringMap(j["fixed"]),
                    origin: (j["origin"] as? String).flatMap(TermOrigin.init(rawValue:)) ?? .user)
    }

    static func terms(_ v: Any?) -> [Term] {
        ((v as? [[String: Any]]) ?? []).map(term)
    }

    static func strings(_ v: Any?) -> [String] { (v as? [String]) ?? [] }

    static func stringMap(_ v: Any?) -> [String: String] { (v as? [String: String]) ?? [:] }

    /// `[[lo, hi]]` as closed ranges.
    static func ranges(_ v: Any?) -> [ClosedRange<Int>] {
        ((v as? [[Int]]) ?? []).map { $0[0]...$0[1] }
    }
}

/// One fixture case as a Swift Testing argument: shown under its `name`, its JSON kept as data (Sendable).
struct FixtureCase: Sendable, CustomTestStringConvertible {
    let name: String
    private let data: Data

    init(_ object: [String: Any]) {
        name = object["name"] as? String ?? "?"
        data = try! JSONSerialization.data(withJSONObject: object)
    }

    var json: [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }

    var testDescription: String { name }
}
