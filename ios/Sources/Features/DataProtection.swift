import Foundation

/// File protection for what the app keeps about conversations (Application Support/History and Feedback):
/// `completeUnlessOpen`, so the files are encrypted while the device is locked once they are closed, while a file
/// already open (a history flush when the app goes to the background) can still be finished. Every directory gets
/// the class (new files in it inherit it) and every file is written with it.
///
/// iOS only: macOS honours the class too, and there it locks out a process without the data-protection
/// entitlement (`swift test`), so on the Mac the files are written plainly.
enum DataProtection {
    static let fileProtection = FileProtectionType.completeUnlessOpen

    /// The options an iOS write uses: atomic, with the protection class.
    static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]

    #if os(iOS)
    static let enabled = true
    #else
    static let enabled = false
    #endif

    /// Options for `Data.write`.
    static var writeOptions: Data.WritingOptions { enabled ? protectedWriteOptions : [.atomic] }

    /// Creates `dir` if needed and gives it the protection class.
    static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: enabled ? [.protectionKey: fileProtection] : nil)
        protect(dir)
    }

    /// Sets the protection class on an existing file or directory (a copy, a directory made before this).
    static func protect(_ url: URL) {
        guard enabled else { return }
        try? FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
    }
}
