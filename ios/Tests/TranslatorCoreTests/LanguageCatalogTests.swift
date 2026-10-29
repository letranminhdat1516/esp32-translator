import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/language_catalog_test.dart, driven by shared/fixtures/language_catalog.json.

private let catalogFixture = Fixtures.load("language_catalog")

/// A pack with only the fields the catalog reads.
private func packs(_ v: Any?) -> [LanguagePack] {
    (v as! [[String: String]]).map {
        LanguagePack(code: $0["code"]!, appleLocale: "", androidLocale: "", whisperCode: "", label: $0["label"]!,
                     labelLatin: "", script: .latin)
    }
}

private func catalog(_ j: [String: Any]) throws -> LanguageCatalog {
    let caps = j["caps"] as! [String: Any]
    let recognizers = (caps["recognizers"] as! [String: [String]]).mapValues { $0.map { RecognizerKind(rawValue: $0)! } }
    let platform = try #require(CatalogPlatform(rawValue: j["platform"] as! String))
    return LanguageCatalog(
        packs: packs(j["packs"] ?? catalogFixture["packs"]),
        caps: Capabilities(recognizers: recognizers, translatable: Set(Fixtures.strings(caps["translatable"])),
                           vietnameseVoice: true),
        platform: platform,
        onlineConsent: Set(Fixtures.strings(j["consent"])))
}

@Suite struct LanguageCatalogFixtureTests {
    @Test(arguments: Fixtures.cases("language_catalog", "offered"))
    func offered(_ c: FixtureCase) throws {
        let j = c.json
        #expect(try catalog(j).offered.map(\.code) == Fixtures.strings(j["expected"]))
    }

    @Test(arguments: Fixtures.cases("language_catalog", "chain"))
    func chain(_ c: FixtureCase) throws {
        let j = c.json
        #expect(try catalog(j).chain(j["code"] as! String).map(\.rawValue) == Fixtures.strings(j["expected"]))
    }

    @Test func constants() {
        #expect(LanguageCatalog.homeCode == catalogFixture["homeCode"] as! String)
        #expect(CatalogPlatform.allCases.map(\.rawValue) == Fixtures.strings(catalogFixture["platforms"]))
        for name in Fixtures.strings(catalogFixture["invalidPlatforms"]) {
            #expect(CatalogPlatform(rawValue: name) == nil, "\(name)")
        }
        #expect(RecognizerKind.allCases.map(\.rawValue) == Fixtures.strings(catalogFixture["chainOrder"]))
    }
}
