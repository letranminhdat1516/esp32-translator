import Foundation
import Observation

/// The app side of pairing by code (ARCHITECTURE §4). With the current firmware no pairing is requested and the
/// app pins as today; with the new firmware iOS shows the system dialog with the board's 6 digits.
enum PairingState: Hashable, Sendable {
    case idle
    case scanning
    /// A board was found; `battery` in percent when known.
    case found(name: String, battery: Int?)
    /// Waiting for the user to compare the code on the board with the system dialog (`code` when known).
    case confirming(name: String, battery: Int?, code: String?)
    case paired(name: String)
    case failed(reason: String)
}

@MainActor
protocol PairingModeling: AnyObject {
    var state: PairingState { get }
    func startScan()
    func confirm()
    func reject()
}

/// A scripted pairing model: demo mode and tests. Track A replaces it with the BLE-backed one.
@Observable @MainActor
final class FakePairingModel: PairingModeling {
    var state: PairingState

    init(state: PairingState = .idle) { self.state = state }

    func startScan() { state = .scanning }

    func confirm() {
        switch state {
        case let .found(name, _), let .confirming(name, _, _): state = .paired(name: name)
        default: break
        }
    }

    func reject() { state = .idle }
}
