import Foundation

// Pure state behind the onboarding screens (track A wires the real permission requests and pairing).

enum PermissionStatus: Hashable, Sendable {
    case notDetermined, granted, denied
}

/// The three permissions of "Cấp quyền".
struct PermissionsSnapshot: Hashable, Sendable {
    var microphone: PermissionStatus = .notDetermined
    var bluetooth: PermissionStatus = .notDetermined
    var speech: PermissionStatus = .notDetermined

    /// "Tiếp tục" is enabled once every permission was answered (a denied one still lets you continue: the app
    /// explains what is missing later).
    var canContinue: Bool { [microphone, bluetooth, speech].allSatisfy { $0 != .notDetermined } }

    /// The first permission still to ask: its "Cho phép" button is the filled one.
    var next: Kind? {
        if microphone == .notDetermined { return .microphone }
        if bluetooth == .notDetermined { return .bluetooth }
        if speech == .notDetermined { return .speech }
        return nil
    }

    enum Kind: CaseIterable, Hashable, Sendable { case microphone, bluetooth, speech }

    func status(_ kind: Kind) -> PermissionStatus {
        switch kind {
        case .microphone: microphone
        case .bluetooth: bluetooth
        case .speech: speech
        }
    }
}

enum LanguageRowStatus {
    /// The status shown for `code`: an explicit `PackStatus` wins; otherwise the session decides (the picked
    /// language downloading or needing a download), else installed.
    static func resolve(code: String, explicit: PackStatus?, session: SessionState?, progress: Double?) -> PackStatus {
        if let explicit { return explicit }
        switch session {
        case let .downloading(c)? where c == code: return .downloading(progress)
        case let .needsDownload(c, _, _)? where c == code: return .notDownloaded(megabytes: nil)
        default: return .installed
        }
    }
}
