import AVFAudio
import CoreBluetooth
import Foundation
import Speech

/// The real permission state and requests behind "Cấp quyền": the microphone (`AVAudioApplication`), speech
/// recognition (`SFSpeechRecognizer`) and Bluetooth (`CBManager.authorization`). Asking for Bluetooth means creating
/// the board link's central (`activateBluetooth`), so there is never a second central. Results land in
/// `services.permissions`.
@MainActor
enum LivePermissions {
    static func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(microphone: microphone, bluetooth: bluetooth, speech: speech)
    }

    static var microphone: PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    static var bluetooth: PermissionStatus {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    static var speech: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// Wires `services.permissionActions` and fills `services.permissions` now.
    static func wire(_ services: AppServices, activateBluetooth: @escaping @MainActor () -> Void) {
        let refresh: @MainActor () -> Void = { [weak services] in services?.permissions = snapshot() }
        services.permissionActions = PermissionActions(
            request: { kind in
                switch kind {
                case .microphone:
                    Task { @MainActor in
                        _ = await AVAudioApplication.requestRecordPermission()
                        refresh()
                    }
                case .speech:
                    SFSpeechRecognizer.requestAuthorization { _ in
                        DispatchQueue.main.async { MainActor.assumeIsolated { refresh() } }
                    }
                case .bluetooth:
                    // The prompt shows when the central is created; the link's state callback refreshes
                    activateBluetooth()
                }
            },
            refresh: refresh)
        refresh()
    }
}
