import Foundation

/// The Vietnamese UI copy, shared with the Android app: `shared/copy/vi.json` (flat keys, placeholders `{name}`).
/// Views never contain a Vietnamese literal; they call `Copy.t("key", ["name": value])`.
enum Copy {
    private final class Anchor {}

    /// The app bundles `shared/copy` as the folder `copy`; on the Mac (`swift test`, the preview) the file is read in
    /// place from the repository.
    static let strings: [String: String] = {
        let candidates = [
            Bundle.main.url(forResource: "vi", withExtension: "json", subdirectory: "copy"),
            Bundle(for: Anchor.self).url(forResource: "vi", withExtension: "json", subdirectory: "copy"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()  // Sources
                .deletingLastPathComponent().deletingLastPathComponent()  // repository root
                .appendingPathComponent("shared/copy/vi.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let map = try? JSONDecoder().decode([String: String].self, from: data) {
                return map
            }
        }
        return [:]
    }()

    /// The text for `key` with every `{name}` replaced from `vars`; an unknown key gives the key itself, an unknown
    /// placeholder stays as written.
    static func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        guard var text = strings[key] else { return key }
        for (name, value) in vars { text = text.replacingOccurrences(of: "{\(name)}", with: value) }
        return text
    }
}
