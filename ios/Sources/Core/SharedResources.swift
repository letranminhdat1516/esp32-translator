import Foundation

/// The data shared with the Android app (`shared/languages/*.json`, `shared/board_glyphs/*.txt`), loaded, never
/// copied. The app bundle holds them as folder references (`languages/`, `board_glyphs/`, see ios/project.yml); under
/// `swift test` (debug builds on the Mac) they are read in place from the repository.
enum SharedResources {
    enum Folder: String {
        case languages
        case boardGlyphs = "board_glyphs"
    }

    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String { "shared resource not found: \(path)" }
    }

    /// Contents of `<folder>/<name>.<ext>`.
    static func data(_ folder: Folder, _ name: String, _ ext: String) throws -> Data {
        guard let url = url(folder, name, ext) else { throw Missing(path: "\(folder.rawValue)/\(name).\(ext)") }
        return try Data(contentsOf: url)
    }

    static func url(_ folder: Folder, _ name: String, _ ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder.rawValue) {
            return url
        }
        #if DEBUG
        let inRepository = repositoryShared.appendingPathComponent("\(folder.rawValue)/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: inRepository.path) { return inRepository }
        #endif
        return nil
    }

    /// The bundled language pack `code` (e.g. "vi").
    static func languagePack(_ code: String) throws -> LanguagePack {
        try LanguagePack.parse(data(.languages, code, "json"))
    }

    #if DEBUG
    /// `shared/` of the checkout this file was compiled from (exists on the build Mac only).
    private static let repositoryShared = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("shared")
    #endif
}
