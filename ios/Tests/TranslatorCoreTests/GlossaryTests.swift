import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/glossary_test.dart: validation and load cases from shared/fixtures/glossary.json, plus the
// storage tests the README leaves to each platform (file round trip, change stream, corrupt file set aside, write
// failure).

private let glossaryFixture = Fixtures.load("glossary")

/// A fresh, empty directory under the temporary directory.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Sequential ids, so tests can name terms.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> String { lock.withLock { n += 1; return "id\(n)" } }
}

private func store(_ dir: URL, clock: () -> Date = { Date() }) -> GlossaryStore {
    let counter = Counter()
    return GlossaryStore(directory: dir, clock: clock, newId: { counter.next() })
}

/// The fixture's name and fields of an error.
private func describe(_ e: GlossaryError) -> [String: AnyHashable] {
    switch e {
    case let .emptyText(field): ["error": "EmptyText", "field": field]
    case let .tooLong(field, limit): ["error": "TooLong", "field": field, "limit": limit]
    case let .tooManyVariants(limit): ["error": "TooManyVariants", "limit": limit]
    case let .tooManyTerms(limit): ["error": "TooManyTerms", "limit": limit]
    case let .forbiddenCharacter(field, codePoint): ["error": "ForbiddenCharacter", "field": field, "codePoint": codePoint]
    case let .duplicateTerm(field, value): ["error": "DuplicateTerm", "field": field, "value": value]
    case let .unknownTerm(id): ["error": "UnknownTerm", "id": id]
    case let .writeFailed(reason): ["error": "WriteFailed", "reason": reason]
    case .readOnly: ["error": "ReadOnly"]
    }
}

/// Runs a fixture `op`: the changed term (nil for remove), or the refusal.
private func run(_ op: String, on s: GlossaryStore, input: [String: Any],
                 targetId: String?) async -> Result<Term?, GlossaryError> {
    let text = input["text"] as? String ?? ""
    let variants = Fixtures.strings(input["variants"])
    let fixed = Fixtures.stringMap(input["fixed"])
    do {
        switch op {
        case "add": return .success(try await s.add(text: text, variants: variants, fixed: fixed))
        case "update": return .success(try await s.update(targetId!, text: text, variants: variants, fixed: fixed))
        default:
            #expect(op == "remove")
            try await s.remove(targetId!)
            return .success(nil)
        }
    } catch {
        return .failure(error)
    }
}

@Suite struct GlossaryFixtureTests {
    @Test func limitsMatchTheFixture() {
        let limits = glossaryFixture["limits"] as! [String: Int]
        #expect(limits["maxTerms"] == GlossaryStore.maxTerms)
        #expect(limits["maxLength"] == GlossaryStore.maxLength)
        #expect(limits["maxVariants"] == GlossaryStore.maxVariants)
    }

    @Test(arguments: Fixtures.cases("glossary", "cases"))
    func validation(_ c: FixtureCase) async throws {
        let j = c.json
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        var existing: [Term] = []
        for e in (j["existing"] as? [[String: Any]]) ?? [] {
            existing.append(try await s.add(text: e["text"] as! String, variants: Fixtures.strings(e["variants"]),
                                            fixed: Fixtures.stringMap(e["fixed"])))
        }
        let before = await s.terms
        let fileBefore = try? Data(contentsOf: dir.appendingPathComponent(GlossaryStore.fileName))
        let input = j["input"] as? [String: Any] ?? [:]
        let targetId = (j["target"] as? Int).map { existing[$0].id } ?? j["targetId"] as? String
        let expect = j["expect"] as! [String: Any]

        let result = await run(j["op"] as! String, on: s, input: input, targetId: targetId)

        switch result {
        case let .success(term):
            #expect(expect["ok"] as? Bool == true, "expected \(expect), got \(String(describing: term))")
            if let term {
                if let text = expect["text"] as? String { #expect(term.text == text) }
                if let variants = expect["variants"] { #expect(term.variants == Fixtures.strings(variants)) }
                if let fixed = expect["fixed"] { #expect(term.fixed == Fixtures.stringMap(fixed)) }
                #expect(term.origin == .user)
            }
            if let all = expect["allTexts"] { #expect(await s.terms.map(\.text) == Fixtures.strings(all)) }
        case let .failure(error):
            let got = describe(error)
            #expect(got["error"] == (expect["error"] as? String).map(AnyHashable.init), "got \(error)")
            for key in ["field", "value"] where expect[key] != nil {
                #expect(got[key] == (expect[key] as? String).map(AnyHashable.init), "\(key) of \(error)")
            }
            for key in ["limit", "codePoint"] where expect[key] != nil {
                #expect(got[key] == (expect[key] as? Int).map(AnyHashable.init), "\(key) of \(error)")
            }
            // Refused: the list and the stored data are unchanged
            #expect(await s.terms == before)
            #expect((try? Data(contentsOf: dir.appendingPathComponent(GlossaryStore.fileName))) == fileBefore)
        }
    }

    @Test(arguments: Fixtures.cases("glossary", "load"))
    func load(_ c: FixtureCase) async throws {
        let j = c.json
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data((j["content"] as! String).utf8).write(to: dir.appendingPathComponent(GlossaryStore.fileName))
        let s = store(dir)
        #expect(await s.recoveredFromCorruption == j["recovered"] as! Bool)
        #expect(await s.terms.map(\.text) == Fixtures.strings(j["texts"]))
    }
}

@Suite struct GlossaryStorageTests {
    @Test func aMissingFileIsAnEmptyGlossary() async throws {
        let dir = try temporaryDirectory().appendingPathComponent("not/yet")
        let s = store(dir)
        #expect(await s.terms.isEmpty)
        #expect(await !s.recoveredFromCorruption)
        _ = try await s.add(text: "Zalo")  // creates the parent directories
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(GlossaryStore.fileName).path))
    }

    @Test func changesSurviveReopening() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        let a = try await s.add(text: "Bến Thành", variants: ["Ben Thanh"], fixed: ["en": "Ben Thanh Market"])
        let b = try await s.add(text: "Grab")
        _ = try await s.update(b.id, text: "Grab Car")
        _ = try await s.add(text: "Zalo")
        let zalo = await s.terms[2]
        try await s.remove(zalo.id)

        let reopened = store(dir)
        #expect(await reopened.terms == [a, Term(id: b.id, text: "Grab Car", origin: .user)])
        #expect(await !reopened.recoveredFromCorruption)
        // The file is the pack term format: a JSON list of terms
        let data = try Data(contentsOf: dir.appendingPathComponent(GlossaryStore.fileName))
        #expect(try JSONDecoder().decode([Term].self, from: data) == [a, Term(id: b.id, text: "Grab Car")])
    }

    @Test func everyChangeIsAnnounced() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        let changes = s.changes()  // subscribed before any change
        let a = try await s.add(text: "A")
        _ = try await s.update(a.id, text: "B")
        try await s.remove(a.id)
        _ = try? await s.add(text: "")  // refused: no event
        _ = try await s.add(text: "C")
        var seen: [[String]] = []
        for await list in changes {
            seen.append(list.map(\.text))
            if seen.count == 4 { break }
        }
        #expect(seen == [["A"], ["B"], [], ["C"]])
    }

    @Test func aCorruptFileIsSetAsideWithATimestamp() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(GlossaryStore.fileName)
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 29)
        (components.hour, components.minute, components.second) = (9, 5, 7)
        let when = Calendar.current.date(from: components)!

        try Data("{oops".utf8).write(to: file)
        let first = store(dir, clock: { when })
        #expect(await first.recoveredFromCorruption)
        #expect(await first.terms.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = dir.appendingPathComponent("glossary.corrupt-20261029-090507.json")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{oops")

        // A second corrupt file in the same second does not overwrite the first
        try Data([0xFF, 0xFE, 0x00]).write(to: file)  // not UTF-8
        let second = store(dir, clock: { when })
        #expect(await second.recoveredFromCorruption)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(
            "glossary.corrupt-20261029-090507-1.json").path))
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{oops")

        // The store works after recovery
        _ = try await second.add(text: "Zalo")
        #expect(await store(dir).terms.map(\.text) == ["Zalo"])
    }

    @Test func aWriteFailureChangesNothing() async throws {
        let dir = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let s = store(dir)
        _ = try await s.add(text: "A")
        let changes = s.changes()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)  // read-only
        await #expect {
            try await s.add(text: "B")
        } throws: { error in
            if case .writeFailed = error as? GlossaryError { return true }
            return false
        }
        #expect(await s.terms.map(\.text) == ["A"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        _ = try await s.add(text: "C")
        for await list in changes {  // the failed write announced nothing
            #expect(list.map(\.text) == ["A", "C"])
            break
        }
    }

    @Test func anUnreadableFileIsSetAsideNotOverwritten() async throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent(GlossaryStore.fileName)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"[{"id":"a","text":"Zalo"}]"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)  // cannot be read
        let s = store(dir)
        #expect(await s.recoveredFromCorruption)
        #expect(await s.terms.isEmpty)
        #expect(await !s.isReadOnly)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("glossary.corrupt-") }
        #expect(aside.count == 1)
        let asideURL = dir.appendingPathComponent(aside[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: asideURL.path)
        #expect(try String(contentsOf: asideURL, encoding: .utf8) == #"[{"id":"a","text":"Zalo"}]"#)
        _ = try await s.add(text: "Grab")  // a fresh file beside the one set aside
        #expect(await store(dir).terms.map(\.text) == ["Grab"])
    }

    @Test func aFileThatCannotBeSetAsideOpensReadOnly() async throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent(GlossaryStore.fileName)
        let content = Data(#"[{"id":"a","text":"Zalo"}]"#.utf8)
        try content.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)  // no rename
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let s = store(dir)
        #expect(await s.recoveredFromCorruption)
        #expect(await s.isReadOnly)
        #expect(await s.terms.isEmpty)
        let changes = s.changes()
        // Every write is refused, before touching the disk
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        await #expect(throws: GlossaryError.readOnly) { try await s.add(text: "Grab") }
        await #expect(throws: GlossaryError.readOnly) { try await s.update("a", text: "Grab") }
        await #expect(throws: GlossaryError.readOnly) { try await s.remove("a") }
        // The user's data is untouched
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [GlossaryStore.fileName])
        await s.close()
        for await list in changes { Issue.record("no change expected, got \(list)") }
    }

    @Test func duplicateIdsOnLoadAreCorruption() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"[{"id":"a","text":"Zalo"},{"id":"a","text":"Grab"}]"#.utf8)
            .write(to: dir.appendingPathComponent(GlossaryStore.fileName))
        let s = store(dir)
        #expect(await s.recoveredFromCorruption)
        #expect(await s.terms.isEmpty)
    }

    @Test func closeEndsTheChangeStreams() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir)
        let changes = s.changes()
        _ = try await s.add(text: "A")
        await s.close()
        var seen: [[String]] = []
        for await list in changes { seen.append(list.map(\.text)) }  // ends after close
        #expect(seen == [["A"]])
        // A stream asked for after close is already finished
        for await _ in s.changes() { Issue.record("stream after close must be finished") }
    }

    @Test func theDefaultDirectoryIsApplicationSupport() throws {
        let dir = try GlossaryStore.defaultDirectory()
        #expect(dir.path.contains("Application Support"))
    }
}
