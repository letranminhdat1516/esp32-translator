import Foundation
import Testing
@testable import TranslatorCore

// Driven by shared/fixtures/board_text.json, and checks that the Swift
// transliteration tables are exactly shared/fixtures/translit.json (the export of translit.dart).

private let translitFixture = Fixtures.load("translit")

/// The glyph lists of shared/board_glyphs, read in place.
private let sharedGlyphs: BoardGlyphSets = {
    func text(_ name: String) -> String {
        try! String(contentsOf: Fixtures.sharedDirectory.appendingPathComponent("board_glyphs/\(name).txt"),
                    encoding: .utf8)
    }
    return try! BoardGlyphSets.parse(cjk: text("cjk"), hangul: text("hangul"), thai: text("thai"))
}()

private let sharedBoardText = BoardText(glyphs: sharedGlyphs)

/// The case's own `glyphs`, or the shared lists.
private func boardText(_ j: [String: Any]) -> BoardText {
    guard let g = j["glyphs"] as? [String: Any] else { return sharedBoardText }
    return BoardText(glyphs: BoardGlyphSets(cjk: Fixtures.ranges(g["cjk"]), hangul: Fixtures.ranges(g["hangul"]),
                                            thai: Fixtures.ranges(g["thai"])))
}

private func sets(_ v: Any?) -> FontSets { FontSets(rawValue: UInt32(v as! Int)) }

@Suite struct BoardTextFixtureTests {
    @Test(arguments: Fixtures.cases("board_text", "ranges"))
    func ranges(_ c: FixtureCase) {
        let j = c.json
        let b = boardText(j)
        let r = b.ranges(sets(j["fontSets"]))
        if let expected = j["expected"] { #expect(r == Fixtures.ranges(expected)) }
        if let same = j["sameAs"] { #expect(r == b.ranges(sets(same))) }
        if let last = j["expectedLast"] as? [Int] { #expect(r.last == last[0]...last[1]) }
        if let from = j["noneFrom"] as? Int { #expect(!r.contains { $0.lowerBound >= from }) }
    }

    @Test(arguments: Fixtures.cases("board_text", "isDrawable"))
    func isDrawable(_ c: FixtureCase) {
        let j = c.json
        #expect(boardText(j).isDrawable(j["codePoint"] as! Int, sets(j["fontSets"])) == j["expected"] as! Bool)
    }

    @Test(arguments: Fixtures.cases("board_text", "parseRanges"))
    func parseRanges(_ c: FixtureCase) {
        let j = c.json
        let input = j["input"] as! String
        if j["error"] as? Bool == true {
            #expect(throws: BoardGlyphSets.BadRange.self) { try BoardGlyphSets.parseRanges(input) }
        } else {
            #expect((try? BoardGlyphSets.parseRanges(input)) == Fixtures.ranges(j["expected"]))
        }
    }

    @Test(arguments: Fixtures.cases("board_text", "encode"))
    func encode(_ c: FixtureCase) {
        let j = c.json
        #expect(boardText(j).encode(j["input"] as! String, sets(j["fontSets"])) == j["expected"] as! String)
    }

    @Test func encodeInvariants() {
        let inv = Fixtures.load("board_text")["encodeInvariants"] as! [String: Any]
        for raw in inv["fontSets"] as! [Int] {
            let fs = FontSets(rawValue: UInt32(raw))
            for sample in inv["samples"] as! [String] {
                let out = sharedBoardText.encode(sample, fs)
                let label = "\(sample.unicodeScalars.map { String($0.value, radix: 16) }) with \(raw) → \(out)"
                #expect(!out.isEmpty, "\(label)")
                #expect(out.unicodeScalars.allSatisfy { $0 == " " || sharedBoardText.isDrawable(Int($0.value), fs) },
                        "\(label)")
                #expect(!out.hasPrefix(" ") && !out.hasSuffix(" ") && !out.contains("  "), "\(label)")
            }
        }
    }

    /// The app loads the same lists from its bundle (or, under `swift test`, from the repository).
    @Test func bundledListsAreTheSharedOnes() {
        #expect(BoardGlyphSets.shared == sharedGlyphs)
        #expect(BoardText().ranges([.cjk, .hangul, .thai]) == sharedBoardText.ranges([.cjk, .hangul, .thai]))
    }
}

@Suite struct TranslitTableTests {
    private func scalarMap(_ v: Any?) -> [Unicode.Scalar: String] {
        var out: [Unicode.Scalar: String] = [:]
        for (k, value) in v as! [String: String] {
            #expect(k.unicodeScalars.count == 1, "key \(k)")
            out[k.unicodeScalars.first!] = value
        }
        return out
    }

    @Test func letterTablesAreTheExport() {
        #expect(Translit.cyrillic == scalarMap(translitFixture["cyrillic"]))
        #expect(Translit.greek == scalarMap(translitFixture["greek"]))
        #expect(Translit.latinSpecialTable == scalarMap(translitFixture["latinSpecial"]))
        #expect(Translit.punctuation == scalarMap(translitFixture["punctuation"]))
        #expect(Translit.digitZeros.map(Int.init) == translitFixture["digitZeros"] as! [Int])
    }

    @Test func capitals() {
        for c in (translitFixture["capitals"] as! [String: Any])["cases"] as! [[String: Any]] {
            let letter = (c["letter"] as! String).unicodeScalars.first!
            #expect(Translit.letter(letter, allCaps: c["allCaps"] as! Bool) == c["expected"] as? String, "\(c)")
        }
    }

    @Test func upsilonAfterOmicron() {
        let u = translitFixture["upsilonAfterOmicron"] as! [String: Any]
        let omicrons = (u["omicrons"] as! [String]).map { $0.unicodeScalars.first! }
        #expect(omicrons.allSatisfy(Translit.isOmicron))
        for letter in u["letters"] as! [String] {
            #expect(Translit.letter(letter.unicodeScalars.first!, afterOmicron: true) == u["latin"] as? String)
        }
    }

    @Test func kanaTablesAreTheExport() {
        let k = translitFixture["kana"] as! [String: Any]
        #expect(Translit.hiragana == scalarMap(k["hiragana"]))
        #expect(Translit.smallY == scalarMap(k["smallY"]))
        #expect(k["hiraganaRange"] as! [Int] == [Int(Translit.hiraganaRange.lowerBound),
                                                  Int(Translit.hiraganaRange.upperBound)])
        #expect(k["katakanaRange"] as! [Int] == [Int(Translit.katakanaRange.lowerBound),
                                                  Int(Translit.katakanaRange.upperBound)])
        #expect(k["katakanaOffset"] as! Int == Int(Translit.katakanaOffset))
        #expect(k["sokuon"] as! String == String(Translit.sokuon))
        #expect(k["n"] as! String == String(Translit.n))
        #expect(Set((k["nApostropheBefore"] as! [String]).map { $0.unicodeScalars.first!.value })
                == Set(Translit.nApostropheBefore.map(\.value)))
        #expect(Set((k["silent"] as! [String]).map { $0.unicodeScalars.first!.value })
                == Set(Translit.silent.map(\.value)))
        #expect(Fixtures.ranges(k["isKana"]) == Translit.kanaRanges.map { Int($0.lowerBound)...Int($0.upperBound) })
    }
}
