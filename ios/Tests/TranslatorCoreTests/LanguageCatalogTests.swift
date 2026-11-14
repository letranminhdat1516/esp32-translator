import Foundation
import Testing
@testable import TranslatorCore

// Driven by shared/fixtures/language_catalog.json.

private let catalogFixture = Fixtures.load("language_catalog")

/// A pack with only the fields the catalog reads.
private func packs(_ v: Any?) -> [LanguagePack] {
    (v as! [[String: String]]).map {
        LanguagePack(code: $0["code"]!, appleLocale: "", label: $0["label"]!,
                     labelLatin: "", script: .latin)
    }
}

private func catalog(_ j: [String: Any]) -> LanguageCatalog {
    let caps = j["caps"] as! [String: Any]
    let recognizers = (caps["recognizers"] as! [String: [String]]).mapValues { $0.map { RecognizerKind(rawValue: $0)! } }
    return LanguageCatalog(
        packs: packs(j["packs"] ?? catalogFixture["packs"]),
        caps: Capabilities(recognizers: recognizers, translatable: Set(Fixtures.strings(caps["translatable"])),
                           vietnameseVoice: true),
        onlineAllowed: j["online"] as? Bool ?? false,
        onlineConsent: Set(Fixtures.strings(j["consent"])))
}

@Suite struct LanguageCatalogFixtureTests {
    @Test(arguments: Fixtures.cases("language_catalog", "offered"))
    func offered(_ c: FixtureCase) throws {
        let j = c.json
        #expect(catalog(j).offered.map(\.code) == Fixtures.strings(j["expected"]))
    }

    @Test(arguments: Fixtures.cases("language_catalog", "chain"))
    func chain(_ c: FixtureCase) throws {
        let j = c.json
        #expect(catalog(j).chain(j["code"] as! String).map(\.rawValue) == Fixtures.strings(j["expected"]))
    }

    @Test func constants() {
        #expect(LanguageCatalog.homeCode == catalogFixture["homeCode"] as! String)
        #expect(RecognizerKind.allCases.map(\.rawValue) == Fixtures.strings(catalogFixture["chainOrder"]))
    }
}
