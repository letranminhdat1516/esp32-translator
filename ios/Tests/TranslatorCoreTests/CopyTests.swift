import XCTest
@testable import TranslatorCore

final class CopyTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private var uiFiles: [URL] {
        ["UIState", "LanguageSheet", "ReadinessView", "GlossaryView", "ContentView"].map {
            root.appendingPathComponent("ios/Sources/UI/\($0).swift")
        }
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func matches(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range(at: 1), in: s)!]) }
    }

    private func jsonKeys() throws -> Set<String> {
        let data = try Data(contentsOf: root.appendingPathComponent("shared/copy/vi.json"))
        return Set(try JSONDecoder().decode([String: String].self, from: data).keys)
    }

    /// Keys written as `Copy.t("key")`, plus any literal in a key namespace of the file (keys chosen in a ternary).
    private func swiftKeys() throws -> Set<String> {
        let namespaces = Set(try jsonKeys().map { String($0.split(separator: ".")[0]) })
        let literal = #""([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)""#
        var keys = Set<String>()
        // The conversation controller speaks and shows a few texts of its own (the unclear cue)
        for url in uiFiles + [root.appendingPathComponent("ios/Sources/App/ConversationController.swift")] {
            let code = try text(url)
            keys.formUnion(matches(#"Copy\.t\("([A-Za-z0-9.]+)""#, in: code))
            keys.formUnion(matches(literal, in: code).filter { namespaces.contains(String($0.split(separator: ".")[0])) })
        }
        return keys
    }

    func testSubstitution() {
        XCTAssertEqual(Copy.t("header.pair", ["label": "English"]), "Tiếng Việt sang English")
        XCTAssertEqual(Copy.t("missing.translation", ["from": "A", "to": "B"]), "Bản dịch A → B")
        XCTAssertEqual(Copy.t("header.pair"), "Tiếng Việt sang {label}")
        XCTAssertEqual(Copy.t("no.such.key"), "no.such.key")
    }

    func testEveryKeyTheSwiftUIUsesExists() throws {
        let keys = try jsonKeys()
        let used = try swiftKeys()
        XCTAssertFalse(used.isEmpty)
        XCTAssertEqual(used.subtracting(keys), [])
    }

    func testEveryKeyInTheFileIsUsedByOneOfTheApps() throws {
        var used = try swiftKeys()
        // The same folders the Android copy test scans: screens, the controller and the composition root.
        var androidFiles = [root.appendingPathComponent("android/src/engine/ConversationController.ts")]
        for dir in ["android/src/ui", "android/src/app"] {
            let url = root.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".ts") || name.hasSuffix(".tsx") {
                androidFiles.append(url.appendingPathComponent(name))
            }
        }
        for file in androidFiles {
            used.formUnion(matches(#"['"`]([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+)['"`]"#, in: try text(file)))
        }
        XCTAssertEqual(try jsonKeys().subtracting(used).sorted(), [])
    }

    func testNoVietnameseLiteralInTheViews() throws {
        for url in uiFiles {
            let code = try text(url).split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    // Comments may quote the copy; string literals may not
                    if let r = line.range(of: "//") , !line[..<r.lowerBound].contains("\"") { return String(line[..<r.lowerBound]) }
                    return String(line)
                }.joined(separator: "\n")
            let literals = matches(#""((?:[^"\\\n]|\\.)*)""#, in: code).filter { $0.unicodeScalars.contains { !$0.isASCII && CharacterSet.letters.contains($0) } }
            XCTAssertEqual(literals, [], url.lastPathComponent)
        }
    }

    func testGlossaryErrorNamesMapToMessages() {
        XCTAssertEqual(GlossaryMessages.forErrorName("EmptyText"), "Từ không được để trống")
        XCTAssertEqual(GlossaryMessages.forErrorName("TooLong"), "Tối đa 64 ký tự")
        XCTAssertEqual(GlossaryMessages.forErrorName("TooManyTerms"), "Tối đa 500 từ")
        XCTAssertEqual(GlossaryMessages.forErrorName("ForbiddenCharacter"), "Có ký tự không hợp lệ")
        XCTAssertEqual(GlossaryMessages.forErrorName("DuplicateTerm"), "Từ này đã có trong từ điển")
        XCTAssertEqual(GlossaryMessages.forErrorName("TooManyVariants"), "Tối đa 8 cách viết khác")
        XCTAssertNil(GlossaryMessages.forErrorName("UnknownTerm"))
    }
}
