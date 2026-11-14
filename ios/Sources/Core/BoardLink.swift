import Foundation

// The board link contract. ESPLink (Sources/BLE) adopts it; FakeBoardLink stands in for it in tests.

/// Connection state of the board link.
enum BoardState: Hashable, Sendable {
    case off, scanning, connecting, ready
}

extension BoardProtocol {
    /// Unread audio packets kept per `audio` subscriber (`.bufferingNewest`): a stalled consumer drops the oldest
    /// packets instead of growing memory. The other board and engine streams are unbounded.
    static let audioBufferPackets = 64
}

/// An event the board sends on the control characteristic.
enum BoardControl: Hashable, Sendable {
    /// The board's mic was switched by the on-screen button (control notify, first byte non-zero = on);
    /// `ESPLink.onMicChange`.
    case micChanged(Bool)
}

/// The phone's side of the subtitle board. Event properties are broadcast: every access returns a new `AsyncStream`
/// that receives every event sent after that access.
///
/// Subscribing inside a Task is a race: in `Task { for await s in link.state { … } }` the property is read only when
/// the Task first runs, so events sent before that are lost. Call `events()` first (it subscribes synchronously) and
/// hand its streams to the Task; read `currentState` for the state before the subscription.
protocol BoardLink: AnyObject, Sendable {
    var state: AsyncStream<BoardState> { get }
    /// Audio packets from the board mic (`…0002` notifications); buffers the newest
    /// `BoardProtocol.audioBufferPackets` unread packets per subscriber.
    var audio: AsyncStream<Data> { get }
    /// Board-originated control events.
    var control: AsyncStream<BoardControl> { get }

    /// What the board can render. Without a `…0005` characteristic (older firmware) this is
    /// `BoardInfo(protocolVersion: 0, fontSets: .latinVI)`.
    var info: BoardInfo { get }

    /// The latest state (also sent on `state`), for a subscriber that arrives after `.ready`.
    var currentState: BoardState { get }

    /// Frames (`BoardProtocol.frameText`) and writes `text`; a new message replaces an unsent one.
    func sendText(_ text: String, kind: TextKind) async
    /// Switches the board's mic (control characteristic write).
    func setBoardMic(_ on: Bool) async
}

/// One subscription to every `BoardLink` event stream, all made before `events()` returns.
struct BoardEvents: Sendable {
    let state: AsyncStream<BoardState>
    let audio: AsyncStream<Data>
    let control: AsyncStream<BoardControl>
}

extension BoardLink {
    /// Subscribes to `state`, `audio` and `control` now (synchronously); see the race note on `BoardLink`.
    func events() -> BoardEvents {
        BoardEvents(state: state, audio: audio, control: control)
    }
}
