import Foundation

// Port of app/lib/board/fake_board_link.dart.

/// In-memory `BoardLink` for tests: records writes, emits on demand. Thread safe.
final class FakeBoardLink: BoardLink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentTexts: [(text: String, kind: TextKind)] = []
    private var _micCalls: [Bool] = []
    private var _info = BoardInfo(protocolVersion: 0, fontSets: .latinVI)
    private var _currentState = BoardState.off

    private let stateEvents = Broadcast<BoardState>()
    private let audioEvents = Broadcast<Data>(bufferingPolicy: .bufferingNewest(BoardProtocol.audioBufferPackets))
    private let controlEvents = Broadcast<BoardControl>()

    init() {}

    /// Every `sendText` call, in order.
    var sentTexts: [(text: String, kind: TextKind)] { lock.withLock { _sentTexts } }
    /// Every `setBoardMic` call, in order.
    var micCalls: [Bool] { lock.withLock { _micCalls } }

    var info: BoardInfo {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }

    var currentState: BoardState { lock.withLock { _currentState } }

    var state: AsyncStream<BoardState> { stateEvents.stream() }
    var audio: AsyncStream<Data> { audioEvents.stream() }
    var control: AsyncStream<BoardControl> { controlEvents.stream() }

    func sendText(_ text: String, kind: TextKind) async {
        lock.withLock { _sentTexts.append((text: text, kind: kind)) }
    }

    func setBoardMic(_ on: Bool) async {
        lock.withLock { _micCalls.append(on) }
    }

    /// Sets `currentState`, then sends `s` to the `state` subscribers.
    func emitState(_ s: BoardState) {
        lock.withLock { _currentState = s }
        stateEvents.send(s)
    }

    func emitAudio(_ data: Data) { audioEvents.send(data) }
    func emitControl(_ c: BoardControl) { controlEvents.send(c) }

    /// Finishes every event stream (current and future subscribers), so `for await` loops in tests end.
    func finishEvents() {
        stateEvents.finish()
        audioEvents.finish()
        controlEvents.finish()
    }
}
