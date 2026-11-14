import Foundation

// Pure state behind the onboarding screens: permission gating, the language rows.

enum PermissionStatus: Hashable, Sendable {
    case notDetermined, granted, denied
}

/// The three permissions of "Cấp quyền".
struct PermissionsSnapshot: Hashable, Sendable {
    var microphone: PermissionStatus = .notDetermined
    var bluetooth: PermissionStatus = .notDetermined
    var speech: PermissionStatus = .notDetermined

    private var all: [PermissionStatus] { [microphone, bluetooth, speech] }

    /// "Tiếp tục" is enabled only when every permission is granted.
    var canContinue: Bool { all.allSatisfy { $0 == .granted } }

    var anyDenied: Bool { all.contains(.denied) }

    /// What the bottom button does: continue (all granted), open the Settings app (something was denied: iOS asks
    /// only once), or nothing yet (still to ask).
    var primary: PrimaryAction {
        if canContinue { return .continueOn }
        if anyDenied { return .openSettings }
        return .waiting
    }

    enum PrimaryAction: Hashable, Sendable { case continueOn, openSettings, waiting }

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

/// The permission requests behind "Cho phép" (the app wires the system prompts; demo mode and tests use these
/// defaults, which grant at once).
@MainActor
struct PermissionActions {
    var request: (PermissionsSnapshot.Kind) -> Void
    /// Reads the current state again (back from the Settings app)
    var refresh: () -> Void

    init(request: @escaping (PermissionsSnapshot.Kind) -> Void = { _ in }, refresh: @escaping () -> Void = {}) {
        self.request = request
        self.refresh = refresh
    }
}

enum LanguageRowStatus {
    /// The status shown for `code`: an explicit `PackStatus` wins; otherwise the session decides (the picked
    /// language downloading or needing a download), else installed.
    /// A download of the picked language in progress always shows (the explicit status from the pack check is
    /// older).
    static func resolve(code: String, explicit: PackStatus?, session: SessionState?, progress: Double?) -> PackStatus {
        if case let .downloading(c)? = session, c == code, explicit != .unsupported { return .downloading(progress) }
        if let explicit { return explicit }
        switch session {
        case let .needsDownload(c, _, _)? where c == code: return .notDownloaded(megabytes: nil)
        default: return .installed
        }
    }

    /// Bundled languages this device cannot offer (not in `offered`, not the home language), as (code, label)
    /// sorted by label: listed greyed out as "Chưa hỗ trợ".
    static func unsupported(names: [String: String], offered: [String], home: String = LanguageCatalog.homeCode)
        -> [(code: String, label: String)] {
        let offered = Set(offered)
        return names.filter { !offered.contains($0.key) && $0.key != home }
            .map { (code: $0.key, label: $0.value) }
            .sorted { $0.label < $1.label }
    }
}

/// What the Pair screen shows for a pairing state (copy keys, the board row).
struct PairDisplay: Hashable {
    var name: String?
    var battery: Int?
    var confirming = false
    var found = false
    var paired = false
    /// An old-firmware board waits for "Vẫn ghép" / "Huỷ".
    var legacy = false
    var failure: PairingFailure?
    var failed: Bool { failure != nil }

    init(_ state: PairingState) {
        switch state {
        case .idle, .scanning: break
        case let .found(name, battery):
            self.name = name; self.battery = battery; found = true
        case let .confirming(name, battery):
            self.name = name; self.battery = battery; confirming = true
        case let .legacyConsent(name, _, _):
            self.name = name; legacy = true
        case let .paired(name):
            self.name = name; paired = true
        case let .failed(f):
            failure = f
        }
    }

    var kickerKey: String {
        if paired { return "pair.kickerPaired" }
        if failed { return "pair.kickerFailed" }
        if legacy { return "pair.kickerLegacy" }
        if confirming || found { return "pair.kickerCode" }
        return "pair.kickerScanning"
    }

    var dialKey: String {
        if paired { return "pair.dialPaired" }
        if failed { return "pair.dialFailed" }
        if legacy { return "pair.dialLegacy" }
        if confirming || found { return "pair.dialCode" }
        return "pair.dialScanning"
    }

    var noteKey: String {
        if paired { return "pair.notePaired" }
        if failed { return "pair.noteFailed" }
        if legacy { return "pair.noteLegacy" }
        if confirming || found { return "pair.noteCode" }
        return "pair.noteScanning"
    }

    var bodyKey: String {
        switch failure {
        case .rejected?: return "pair.bodyRejected"
        case .timeout?: return "pair.bodyTimeout"
        case .lost?: return "pair.bodyLost"
        case .bluetoothOff?: return "pair.bodyBluetoothOff"
        case .declined?: return "pair.bodyDeclined"
        case .unverified?: return "pair.bodyUnverified"
        case nil: break
        }
        if paired { return "pair.bodyPaired" }
        if legacy { return "pair.bodyLegacy" }
        if confirming { return "pair.bodyConfirming" }
        if found { return "pair.bodyFound" }
        return "pair.bodyScanning"
    }

    /// While a code is expected: the iOS dialog is the proof (a board that never makes it appear is not
    /// authenticated, README "BLE pairing").
    var dialogHintKey: String? { confirming || found ? "pair.dialogRequired" : nil }
}
