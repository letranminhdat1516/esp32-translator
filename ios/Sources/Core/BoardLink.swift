import Foundation

// Port of app/lib/board/board_link.dart. ESPLink (Sources/BLE) adopts this protocol in S2.

/// Connection state of the board link.
enum BoardState: Hashable, Sendable {
    case off, scanning, connecting, ready
}

/// An event the board sends on the control characteristic.
enum BoardControl: Hashable, Sendable {
    /// The board's mic was switched by the on-screen button (control notify, first byte non-zero = on);
    /// `ESPLink.onMicChange`.
    case micChanged(Bool)
}

/// The phone's side of the subtitle board. Event properties are broadcast: every access returns a new `AsyncStream`
/// that receives every event sent after that access.
protocol BoardLink: AnyObject, Sendable {
    var state: AsyncStream<BoardState> { get }
    /// Audio packets from the board mic (`…0002` notifications).
    var audio: AsyncStream<Data> { get }
    /// Board-originated control events.
    var control: AsyncStream<BoardControl> { get }

    /// What the board can render. Without a `…0005` characteristic (older firmware) this is
    /// `BoardInfo(protocolVersion: 0, fontSets: .latinVI)`.
    var info: BoardInfo { get }

    /// Frames (`BoardProtocol.frameText`) and writes `text`; a new message replaces an unsent one.
    func sendText(_ text: String, kind: TextKind) async
    /// Switches the board's mic (control characteristic write).
    func setBoardMic(_ on: Bool) async
}
