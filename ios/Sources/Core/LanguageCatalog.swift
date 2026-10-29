import Foundation

// Port of app/lib/core/language_catalog.dart; contract: shared/fixtures/language_catalog.json.

/// The platform the catalog decides for (the online OS recognizer is offered only on Android).
enum CatalogPlatform: String, CaseIterable, Sendable {
    case ios, android
}

/// Which languages the user can pick as "the other person's", and which recognizers to try for each (R2, P3).
///
/// Combines the bundled packs with what the phone reports (`Capabilities`). A language is offered when it works
/// fully: at least one usable recognizer and offline translation both ways with Vietnamese. The online OS recognizer
/// is usable only on Android and only for languages with consent (`onlineConsent`, language codes the user agreed to
/// send to the OS service). Vietnamese is the home language and is never offered. On iOS the chain is therefore the
/// on-device OS recognizer, then Whisper.
struct LanguageCatalog: Sendable {
    /// Code of the home language, which is always the wearer's.
    static let homeCode = "vi"

    /// The languages to list, sorted by label (lower-cased, UTF-16 order), ties by code.
    let offered: [LanguagePack]

    private let caps: Capabilities
    private let onlineAllowed: Bool
    private let consent: Set<String>

    init(packs: [LanguagePack], caps: Capabilities, platform: CatalogPlatform, onlineConsent: Set<String> = []) {
        self.caps = caps
        onlineAllowed = platform == .android
        consent = onlineConsent
        offered = packs
            .filter {
                $0.code != Self.homeCode && caps.translatable.contains($0.code)
                    && !Self.chain($0.code, caps, platform == .android, onlineConsent).isEmpty
            }
            .sorted { a, b in
                // Dart `compareTo`: UTF-16 code unit order, not Swift's String order
                let (la, lb) = (a.label.lowercased().utf16, b.label.lowercased().utf16)
                if !la.elementsEqual(lb) { return la.lexicographicallyPrecedes(lb) }
                return a.code.utf16.lexicographicallyPrecedes(b.code.utf16)
            }
    }

    /// The recognizers to try for `code`, best first: the OS on-device one, then Whisper, then (with consent,
    /// Android only) the OS online one.
    func chain(_ code: String) -> [RecognizerKind] {
        Self.chain(code, caps, onlineAllowed, consent)
    }

    private static func chain(_ code: String, _ caps: Capabilities, _ onlineAllowed: Bool,
                              _ consent: Set<String>) -> [RecognizerKind] {
        let have = caps.recognizers[code] ?? []
        return RecognizerKind.allCases.filter { kind in
            have.contains(kind) && (kind != .osOnline || (onlineAllowed && consent.contains(code)))
        }
    }
}
