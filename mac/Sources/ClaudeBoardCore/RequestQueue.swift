import Foundation

public actor RequestQueue {
    private struct Pending {
        let id: UInt32
        let message: BoardMessage
        var continuation: CheckedContinuation<Decision?, Never>?
    }

    private let outbox: AsyncStream<BoardMessage>.Continuation   // single FIFO so board traffic never reorders
    private let timeout: Duration
    private var queue: [Pending] = []          // queue[0] is on the board
    private var nextId = UInt32.random(in: 1 ... 0x7fff_ffff)

    public init(send: @escaping @Sendable (BoardMessage) async -> Void, timeout: Duration = .seconds(90)) {
        let (stream, continuation) = AsyncStream<BoardMessage>.makeStream()
        self.outbox = continuation
        self.timeout = timeout
        Task {
            for await message in stream { await send(message) }
        }
    }

    deinit { outbox.finish() }

    /// Ids are never 0: the board uses 0 as "no pending request".
    private func allocateId() -> UInt32 {
        if nextId == 0 { nextId = 1 }
        let id = nextId
        nextId &+= 1
        return id
    }

    func seedNextId(_ value: UInt32) { nextId = value }

    public func ask(project: String, tool: String, summary: String) async -> Decision? {
        let id = allocateId()
        let message = BoardMessage.permission(id: id, project: project, tool: tool, summary: summary)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Pending(id: id, message: message, continuation: c))
                if queue.count == 1 { outbox.yield(message) }
            }
        } onCancel: {
            Task { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
    }

    public func handle(_ answer: Answer) {
        guard queue.first?.id == answer.id else { return }      // only the request shown on the board
        finish(answer.id, with: answer.decision, cancelOnBoard: false)
    }

    public func boardDisconnected() {
        let all = queue
        queue.removeAll()
        for p in all { p.continuation?.resume(returning: nil) }
    }

    public func notifyFinished(project: String, line: String) async {
        outbox.yield(.finished(id: allocateId(), project: project, line: line))
    }

    private func finish(_ id: UInt32, with decision: Decision?, cancelOnBoard: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = index == 0
        let p = queue.remove(at: index)
        p.continuation?.resume(returning: decision)
        if wasShown {
            if cancelOnBoard { outbox.yield(.cancel(id: id)) }
            if let next = queue.first { outbox.yield(next.message) }
        }
    }
}
