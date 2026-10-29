import Foundation
import Testing
@testable import TranslatorCore

// Port of app/test/core/term_protector_test.dart, driven by shared/fixtures/terms.json (Review Focus 3).

private let termsFixture = Fixtures.load("terms")

@Suite struct TermProtectorFixtureTests {
    @Test(arguments: Fixtures.cases("terms", "cases"))
    func termCase(_ c: FixtureCase) throws {
        let j = c.json
        let protector = TermProtector()
        let placeholder = j["placeholder"] as? String ?? termsFixture["defaultPlaceholder"] as! String
        let text = j["text"] as! String
        let terms = Fixtures.terms(j["terms"])
        let target = j["target"] as! String
        if let error = j["error"] as? String {
            #expect(error == "invalidPlaceholder")
            #expect(throws: TermProtector.InvalidPlaceholder.self) {
                try protector.mask(text, terms: terms, target: target, placeholder: placeholder)
            }
            return
        }
        let masked = try protector.mask(text, terms: terms, target: target, placeholder: placeholder)
        #expect(masked.text == j["masked"] as! String)
        if let isEmpty = j["isEmpty"] as? Bool { #expect(masked.isEmpty == isEmpty) }
        for r in (j["restores"] as? [[String: Any]]) ?? [] {
            let translated = r["translated"] as! String
            #expect(protector.restore(translated, masked) == r["expected"] as? String, "restore \(translated)")
        }
    }

    @Test func defaultPlaceholderMatchesTheFixture() {
        #expect(TermProtector.defaultPlaceholder == termsFixture["defaultPlaceholder"] as! String)
    }
}
