import Foundation

/// What the board answered for the request it showed.
public enum BoardResponse: Equatable, Sendable {
    case allow, deny, alwaysAllow
    /// One bitmask per question: bit i = option i chosen, bit 7 = the spoken Other answer (its text in `others`)
    case answers([UInt8], others: [Int: String] = [:])
    /// Deny with the reason the user spoke on the board
    case denyWithReason(String)
}

/// The answers a request accepts.
public enum RequestShape: Equatable, Sendable {
    case permission(alwaysOffered: Bool)
    /// options[q] = option count of question q; multi[q] = several options may be chosen
    case question(options: [Int], multi: [Bool])

    /// Mask bit of a question's spoken Other answer
    public static let otherBit: UInt8 = 0x80

    /// The response a board input stands for, or nil when it does not fit this request. `others`: questions
    /// that have a spoken Other text (bit 7 is only valid for those).
    public func accept(_ input: BoardInput, others: Set<Int> = []) -> BoardResponse? {
        switch (self, input) {
        case (.permission(let always), .choice(_, let c)):
            switch c {
            case .allow: return .allow
            case .deny: return .deny
            case .alwaysAllow: return always ? .alwaysAllow : nil
            }
        case (.question(let options, let multi), .answers(_, let masks)):
            guard masks.count == options.count, multi.count == options.count else { return nil }
            for (i, m) in masks.enumerated() {
                guard (1...7).contains(options[i]) else { return nil }
                var valid = UInt8(truncatingIfNeeded: (1 << options[i]) - 1)
                if others.contains(i) { valid |= Self.otherBit }
                guard m != 0, m & ~valid == 0, multi[i] || m.nonzeroBitCount == 1 else { return nil }
            }
            return .answers(masks)
        default:
            return nil
        }
    }
}

public actor RequestQueue {
    private struct Pending {
        let id: UInt32
        let messages: [BoardMessage]
        let shape: RequestShape
        var continuation: CheckedContinuation<BoardResponse?, Never>?
        /// Spoken Other answers stored by the board's voice Send (question index → text)
        var others: [Int: String] = [:]
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

    /// Ids are never 0: the board uses 0 as "no pending request" and for its own events.
    private func allocateId() -> UInt32 {
        if nextId == 0 { nextId = 1 }
        let id = nextId
        nextId &+= 1
        return id
    }

    func seedNextId(_ value: UInt32) { nextId = value }

    /// Shows a request on the board (when it reaches the head of the queue) and waits for its answer.
    /// nil = timeout, cancellation (the hook went away) or the board disconnected: never a decision.
    public func ask(shape: RequestShape, messages build: @Sendable (UInt32) -> [BoardMessage]) async -> BoardResponse? {
        let id = allocateId()
        let messages = build(id)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.finish(id, with: nil, cancelOnBoard: true) }   // runs on the queue
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Pending(id: id, messages: messages, shape: shape, continuation: c))
                if queue.count == 1 { show(messages) }
            }
        } onCancel: {
            Task { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
    }

    /// A permission request without "Always allow".
    public func ask(project: String, tool: String, summary: String) async -> BoardResponse? {
        await ask(shape: .permission(alwaysOffered: false)) { id in
            [.permission(id: id, project: project, tool: tool, summary: summary)]
        }
    }

    /// Only the request shown on the board can be answered, and only with an answer of its shape.
    public func handle(_ input: BoardInput) {
        let id: UInt32
        switch input {
        case .choice(let i, _), .answers(let i, _): id = i
        case .mode, .focus, .voiceStart, .voiceStop, .voiceCancel, .voiceSend: return
        }
        guard let head = queue.first, head.id == id,
              let response = head.shape.accept(input, others: Set(head.others.keys)) else { return }
        if case .answers(let masks, _) = response {
            let spoken = head.others.filter { q, _ in masks.indices.contains(q) && masks[q] & RequestShape.otherBit != 0 }
            finish(id, with: .answers(masks, others: spoken), cancelOnBoard: false)
        } else {
            finish(id, with: response, cancelOnBoard: false)
        }
    }

    /// The shape of the request on the board, if `id` is that request.
    public func shownShape(id: UInt32) -> RequestShape? {
        guard let head = queue.first, head.id == id else { return nil }
        return head.shape
    }

    /// Stores the spoken Other answer for question `question` of the question request on the board. It becomes
    /// part of the answer only if the board's answers tick it (bit 7). A later call replaces the text.
    public func setOther(id: UInt32, question: Int, text: String) -> Bool {
        guard !text.isEmpty, let head = queue.first, head.id == id,
              case .question(let options, _) = head.shape, options.indices.contains(question) else { return false }
        queue[0].others[question] = text
        return true
    }

    /// Denies the permission request on the board with the spoken reason. `notice` goes to the board right after
    /// the decision, before the next request is shown.
    public func denyWithReason(id: UInt32, message: String, notice: BoardMessage? = nil) -> Bool {
        guard !message.isEmpty, let head = queue.first, head.id == id, case .permission = head.shape else { return false }
        finish(id, with: .denyWithReason(message), cancelOnBoard: false, notice: notice)
        return true
    }

    /// Non-request traffic (session rows): same FIFO, so it never overtakes a request or a cancel.
    public func post(_ message: BoardMessage) {
        outbox.yield(message)
    }

    public func boardDisconnected() {
        let all = queue
        queue.removeAll()
        for p in all { p.continuation?.resume(returning: nil) }
    }

    public func notifyFinished(project: String, line: String) async {
        outbox.yield(.finished(id: allocateId(), project: project, line: line))
    }

    private func show(_ messages: [BoardMessage]) {
        for m in messages { outbox.yield(m) }
    }

    private func finish(_ id: UInt32, with response: BoardResponse?, cancelOnBoard: Bool, notice: BoardMessage? = nil) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = index == 0
        let p = queue.remove(at: index)
        p.continuation?.resume(returning: response)
        if let notice { outbox.yield(notice) }
        if wasShown {
            if cancelOnBoard { outbox.yield(.cancel(id: id)) }
            if let next = queue.first { show(next.messages) }
        }
    }
}
