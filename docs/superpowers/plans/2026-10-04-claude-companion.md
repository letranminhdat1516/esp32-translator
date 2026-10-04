# Claude Companion Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Approve Claude Code permission prompts and get "Claude finished" notifications on the ESP32 board, over a second BLE link from the Mac.

**Architecture:** Claude Code hooks call a tiny Swift CLI (`claude-board-hook`) that forwards each event over a Unix socket to a Swift daemon (`claude-board`). The daemon holds a CoreBluetooth connection to the board and queues permission requests. The board firmware accepts two BLE connections (iPhone for translation, Mac for Claude), shows requests on a new LVGL screen with Allow/Deny buttons, and notifies the answer back.

**Tech Stack:** Swift 6 package (macOS 14+, Network.framework, CoreBluetooth, Swift Testing), ESP-IDF 5.5 + NimBLE + LVGL 9, host C tests compiled with `cc`.

**Spec:** `docs/superpowers/specs/2026-10-04-claude-companion-design.md`

## Global Constraints

- Nothing is ever auto-approved: no board, no answer, any error or timeout → the hook prints nothing and exits 0 (Claude Code shows its normal prompt).
- Bridge timeout 90 s; `PermissionRequest` hook timeout 100 s.
- Hook decision JSON: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` (or `"deny"`).
- `Stop` and `Notification` (`idle_prompt`) hooks use `"async": true`.
- Socket: `~/.claude-board/sock`, mode 0600.
- BLE: Claude service `A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A`, request char `…0011` (write), answer char `…0012` (notify). Translation service and protocol unchanged.
- Board accepts 2 BLE connections. Translation keeps working while the Claude screen is shown.
- Board UI text is English.

## Review Focus

1. **Two Claude sessions ask at once**: the second request must wait and be shown after the first is answered, not overwrite it (Task 2 test `queuesSecondRequestUntilFirstAnswered`).
2. **Hook killed or Claude moves on** (user answered in the terminal first): the board request must disappear (cancel message), and a late tap must not be applied (Task 2 tests `cancelsWhenHookDisconnects` + `ignoresAnswerForUnknownId`, Task 4 test `cancel_clears_pending`, Task 6 step 4 Ctrl-C check on the device).
3. **Mac connects but the iPhone doesn't**: translation must not start and the board must not deep-sleep while the Mac link is up (Task 4 step "connection roles", verified in Task 7).
4. **Long commands / multi-line / non-ASCII summaries** (Vietnamese paths, emoji): summary trimmed by characters, never splitting UTF-8 (Task 1 test `trimsByCharacterNotByte`, Task 4 test `chunked_utf8_roundtrip`).
5. **Daemon not running or board out of range**: hook returns within 1 s with no output (Task 3 test `noDaemonFallsThroughFast`).

---

## File structure

```
mac/                                   Swift package (new)
  Package.swift
  Sources/ClaudeBoardCore/
    HookEvent.swift        parse hook stdin JSON → HookEvent
    Summary.swift          one-line summary + project name
    BoardMessage.swift     BLE wire format (encode request/cancel/finished, decode answer)
    RequestQueue.swift     one-at-a-time queue, timeouts, cancel
    SocketProtocol.swift   newline-delimited JSON between hook and daemon
  Sources/claude-board-hook/main.swift
  Sources/claude-board/
    main.swift             socket server + queue + BLE wiring
    BoardLink.swift        protocol BoardLink + CoreBluetooth implementation
  Tests/ClaudeBoardCoreTests/*.swift
  install.sh               build, install binaries, launchd agent, merge hooks into ~/.claude/settings.json
firmware/main/
  claude_proto.c/.h        pure C: chunk assembly + message parsing + answer encoding (host-testable)
  claude_ui.c              LVGL Claude screen
  chime.c                  short tone on the ES8311 speaker
  ble_link.c               (modify) 2 connections, connection roles, Claude service
  main.c / ui.c / app.h    (modify) mode switch, sleep rule
firmware/test/
  test_claude_proto.c      host tests (cc)
  claude_ble_test.py       bleak script acting as the Mac
```

---

### Task 1: Core types — hook events, summary, BLE wire format

**Files:**
- Create: `mac/Package.swift`, `mac/Sources/ClaudeBoardCore/{HookEvent,Summary,BoardMessage}.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/CoreTests.swift`

**Interfaces:**
- Produces:
  - `struct HookEvent { let name: String; let sessionId: String; let cwd: String; let toolName: String?; let toolInput: [String: JSONValue]; let notificationType: String?; let lastAssistantMessage: String?; static func parse(_ data: Data) throws -> HookEvent }`
  - `enum JSONValue: Codable { case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null }`
  - `enum Summary { static func project(cwd: String) -> String; static func permission(_ e: HookEvent, maxChars: Int = 120) -> String; static func trim(_ s: String, maxChars: Int) -> String }`
  - `enum BoardMessage { case permission(id: UInt32, project: String, tool: String, summary: String); case finished(id: UInt32, project: String, line: String); case cancel(id: UInt32) ; func encode() -> Data; static func chunks(_ data: Data, maxChunk: Int) -> [Data] }`
  - `enum Decision: UInt8 { case allow = 1, deny = 2 }`, `struct Answer { let id: UInt32; let decision: Decision; static func decode(_ d: Data) -> Answer? }`

- [ ] **Step 1: Package manifest**

```swift
// mac/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeBoardCore"),
        .executableTarget(name: "claude-board-hook", dependencies: ["ClaudeBoardCore"]),
        .executableTarget(name: "claude-board", dependencies: ["ClaudeBoardCore"]),
        .testTarget(name: "ClaudeBoardCoreTests", dependencies: ["ClaudeBoardCore"]),
    ]
)
```

Create placeholder `Sources/claude-board-hook/main.swift` and `Sources/claude-board/main.swift` containing only `print("todo")` so the package builds; Tasks 3 and 5 replace them.

- [ ] **Step 2: Write the failing tests**

```swift
// mac/Tests/ClaudeBoardCoreTests/CoreTests.swift
import Foundation
import Testing
@testable import ClaudeBoardCore

let bashRequest = """
{"session_id":"s1","cwd":"/Users/me/Documents/esp32-translator","hook_event_name":"PermissionRequest",
 "tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run tests"}}
""".data(using: .utf8)!

@Test func parsesPermissionRequest() throws {
    let e = try HookEvent.parse(bashRequest)
    #expect(e.name == "PermissionRequest")
    #expect(e.toolName == "Bash")
    #expect(Summary.project(cwd: e.cwd) == "esp32-translator")
    #expect(Summary.permission(e) == "npm test -- --watch=false")
}

@Test func summaryPicksFilePathForEdits() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/p/src/app/main.swift","old_string":"a","new_string":"b"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "src/app/main.swift")
}

@Test func summaryFallsBackToFirstString() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"mcp__x__y","tool_input":{"query":"weather in Hanoi"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "weather in Hanoi")
}

@Test func trimsByCharacterNotByte() {
    let s = String(repeating: "ữ", count: 200)
    let t = Summary.trim(s, maxChars: 10)
    #expect(t.count == 10)
    #expect(t.hasSuffix("…"))
    #expect(String(data: t.data(using: .utf8)!, encoding: .utf8) == t)
}

@Test func multilineCommandsBecomeOneLine() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"cd x\nmake all"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "cd x ⏎ make all")
}

@Test func encodesPermissionMessage() {
    let d = BoardMessage.permission(id: 0x01020304, project: "p", tool: "Bash", summary: "ls").encode()
    #expect(Array(d) == [0, 0x04, 0x03, 0x02, 0x01] + Array("p\nBash\nls".utf8))
}

@Test func encodesCancel() {
    #expect(Array(BoardMessage.cancel(id: 7).encode()) == [2, 7, 0, 0, 0])
}

@Test func chunksCarryFirstAndLastFlags() {
    let data = Data(repeating: 0x41, count: 25)
    let c = BoardMessage.chunks(data, maxChunk: 11)          // 10 payload bytes per chunk
    #expect(c.count == 3)
    #expect(c[0].first == 0x01 && c[1].first == 0x00 && c[2].first == 0x02)
    #expect(c.map { $0.count - 1 }.reduce(0, +) == 25)
    #expect(BoardMessage.chunks(Data([1]), maxChunk: 20).first?.first == 0x03)
}

@Test func decodesAnswer() {
    let a = Answer.decode(Data([0x04, 0x03, 0x02, 0x01, 1]))
    #expect(a?.id == 0x01020304 && a?.decision == .allow)
    #expect(Answer.decode(Data([1, 2, 3])) == nil)
    #expect(Answer.decode(Data([1, 0, 0, 0, 9])) == nil)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd mac && swift test`
Expected: compile errors (`HookEvent`, `Summary`, `BoardMessage`, `Answer` not found).

- [ ] **Step 4: Implement**

```swift
// mac/Sources/ClaudeBoardCore/HookEvent.swift
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

public struct HookEvent: Sendable {
    public let name: String
    public let sessionId: String
    public let cwd: String
    public let toolName: String?
    public let toolInput: [String: JSONValue]
    public let notificationType: String?
    public let lastAssistantMessage: String?
    public let transcriptPath: String?

    private struct Raw: Decodable {
        let hook_event_name: String
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let tool_input: [String: JSONValue]?
        let notification_type: String?
        let last_assistant_message: String?
        let transcript_path: String?
    }

    public static func parse(_ data: Data) throws -> HookEvent {
        let r = try JSONDecoder().decode(Raw.self, from: data)
        return HookEvent(name: r.hook_event_name, sessionId: r.session_id ?? "", cwd: r.cwd ?? "",
                         toolName: r.tool_name, toolInput: r.tool_input ?? [:],
                         notificationType: r.notification_type,
                         lastAssistantMessage: r.last_assistant_message, transcriptPath: r.transcript_path)
    }
}
```

```swift
// mac/Sources/ClaudeBoardCore/Summary.swift
import Foundation

public enum Summary {
    public static func project(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    /// The single most useful field of the tool input, on one line
    public static func permission(_ e: HookEvent, maxChars: Int = 120) -> String {
        let input = e.toolInput
        let raw: String
        if let cmd = input["command"]?.string {
            raw = cmd
        } else if let path = input["file_path"]?.string ?? input["notebook_path"]?.string {
            raw = relative(path, to: e.cwd)
        } else if let url = input["url"]?.string {
            raw = url
        } else if let first = input.keys.sorted().compactMap({ input[$0]?.string }).first {
            raw = first
        } else {
            raw = e.toolName ?? "permission"
        }
        let oneLine = raw.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return trim(oneLine, maxChars: maxChars)
    }

    public static func trim(_ s: String, maxChars: Int) -> String {
        s.count <= maxChars ? s : String(s.prefix(maxChars - 1)) + "…"
    }

    private static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
```

```swift
// mac/Sources/ClaudeBoardCore/BoardMessage.swift
import Foundation

public enum Decision: UInt8, Sendable { case allow = 1, deny = 2 }

public struct Answer: Equatable, Sendable {
    public let id: UInt32
    public let decision: Decision

    public init(id: UInt32, decision: Decision) { self.id = id; self.decision = decision }

    /// [id u32 LE][decision u8]
    public static func decode(_ d: Data) -> Answer? {
        let b = [UInt8](d)
        guard b.count == 5, let decision = Decision(rawValue: b[4]) else { return nil }
        let id = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return Answer(id: id, decision: decision)
    }
}

public enum BoardMessage: Equatable, Sendable {
    case permission(id: UInt32, project: String, tool: String, summary: String)
    case finished(id: UInt32, project: String, line: String)
    case cancel(id: UInt32)

    /// [kind u8][id u32 LE][UTF-8 text]; kind 0 permission, 1 finished, 2 cancel
    public func encode() -> Data {
        let (kind, id, text): (UInt8, UInt32, String) = switch self {
        case .permission(let id, let p, let t, let s): (0, id, "\(p)\n\(t)\n\(s)")
        case .finished(let id, let p, let l): (1, id, "\(p)\n\(l)")
        case .cancel(let id): (2, id, "")
        }
        var d = Data([kind, UInt8(id & 0xff), UInt8(id >> 8 & 0xff), UInt8(id >> 16 & 0xff), UInt8(id >> 24)])
        d.append(contentsOf: text.utf8)
        return d
    }

    /// Splits a message into BLE writes: [flags u8][payload], flags bit0 = first, bit1 = last
    public static func chunks(_ data: Data, maxChunk: Int) -> [Data] {
        let size = max(1, maxChunk - 1)
        var out: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }
            if end == data.count { flags |= 0x02 }
            out.append(Data([flags]) + data[data.startIndex + offset ..< data.startIndex + end])
            offset = end
        } while offset < data.count
        return out
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: all 9 tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac
git commit -m "mac: core types for Claude board bridge (hook events, summary, wire format)"
```

---

### Task 2: Request queue (one request on the board at a time)

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/RequestQueue.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift`

**Interfaces:**
- Consumes: `BoardMessage`, `Answer`, `Decision` (Task 1)
- Produces:
  ```swift
  public actor RequestQueue {
      public init(send: @escaping @Sendable (BoardMessage) async -> Void, timeout: Duration = .seconds(90))
      /// Suspends until the board answers, the request times out, or it is cancelled. nil = fall through.
      public func ask(project: String, tool: String, summary: String) async -> Decision?
      public func handle(_ answer: Answer)
      public func boardDisconnected()          // answer nil to all waiters
      public func notifyFinished(project: String, line: String) async
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift
import Foundation
import Testing
@testable import ClaudeBoardCore

actor Sent {
    var messages: [BoardMessage] = []
    func add(_ m: BoardMessage) { messages.append(m) }
    func permissionIds() -> [UInt32] { messages.compactMap { if case .permission(let id, _, _, _) = $0 { id } else { nil } } }
}

@Test func answersTheWaitingHook() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.permissionIds()[0]
    await q.handle(Answer(id: id, decision: .allow))
    #expect(await d == .allow)
}

@Test func queuesSecondRequestUntilFirstAnswered() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = q.ask(project: "p", tool: "Bash", summary: "two")
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await sent.permissionIds().count == 1)
    let first = await sent.permissionIds()[0]
    await q.handle(Answer(id: first, decision: .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let ids = await sent.permissionIds()
    #expect(ids.count == 2)
    await q.handle(Answer(id: ids[1], decision: .allow))
    #expect(await a == .deny)
    #expect(await b == .allow)
}

@Test func ignoresAnswerForUnknownId() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(200))
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.handle(Answer(id: 999_999, decision: .allow))
    #expect(await d == nil)        // timed out, never approved by a stray answer
}

@Test func timeoutFallsThroughAndCancelsOnBoard() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) }, timeout: .milliseconds(100))
    #expect(await q.ask(project: "p", tool: "Bash", summary: "ls") == nil)
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func cancelsWhenHookDisconnects() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    let t = Task { await q.ask(project: "p", tool: "Bash", summary: "ls") }
    try? await Task.sleep(for: .milliseconds(30))
    t.cancel()
    #expect(await t.value == nil)
    try? await Task.sleep(for: .milliseconds(30))
    let msgs = await sent.messages
    #expect(msgs.contains { if case .cancel = $0 { true } else { false } })
}

@Test func boardDisconnectReleasesWaiters() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let d = q.ask(project: "p", tool: "Bash", summary: "ls")
    try? await Task.sleep(for: .milliseconds(30))
    await q.boardDisconnected()
    #expect(await d == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test --filter RequestQueue`
Expected: compile error `RequestQueue` not found.

- [ ] **Step 3: Implement**

```swift
// mac/Sources/ClaudeBoardCore/RequestQueue.swift
import Foundation

public actor RequestQueue {
    private struct Pending {
        let id: UInt32
        let message: BoardMessage
        var continuation: CheckedContinuation<Decision?, Never>?
    }

    private let send: @Sendable (BoardMessage) async -> Void
    private let timeout: Duration
    private var queue: [Pending] = []          // queue[0] is on the board
    private var nextId = UInt32.random(in: 1 ... 0x7fff_ffff)

    public init(send: @escaping @Sendable (BoardMessage) async -> Void, timeout: Duration = .seconds(90)) {
        self.send = send
        self.timeout = timeout
    }

    public func ask(project: String, tool: String, summary: String) async -> Decision? {
        let id = nextId
        nextId &+= 1
        let message = BoardMessage.permission(id: id, project: project, tool: tool, summary: summary)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Pending(id: id, message: message, continuation: c))
                if queue.count == 1 { Task { await send(message) } }
            }
        } onCancel: {
            Task { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
    }

    public func handle(_ answer: Answer) {
        guard queue.first?.id == answer.id else { return }      // only the request shown on the board
        finishSync(answer.id, with: answer.decision, cancelOnBoard: false)
    }

    public func boardDisconnected() {
        let all = queue
        queue.removeAll()
        for p in all { p.continuation?.resume(returning: nil) }
    }

    public func notifyFinished(project: String, line: String) async {
        let id = nextId
        nextId &+= 1
        await send(.finished(id: id, project: project, line: line))
    }

    private func finish(_ id: UInt32, with decision: Decision?, cancelOnBoard: Bool) {
        finishSync(id, with: decision, cancelOnBoard: cancelOnBoard)
    }

    private func finishSync(_ id: UInt32, with decision: Decision?, cancelOnBoard: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = index == 0
        let p = queue.remove(at: index)
        p.continuation?.resume(returning: decision)
        if wasShown {
            if cancelOnBoard { Task { await send(.cancel(id: id)) } }
            if let next = queue.first { Task { await send(next.message) } }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac && swift test`
Expected: all tests pass (Task 1 + 6 new).

- [ ] **Step 5: Commit**

```bash
git add mac
git commit -m "mac: request queue with one-at-a-time board requests, timeout and cancel"
```

---

### Task 3: Socket protocol and `claude-board-hook`

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/SocketProtocol.swift`
- Replace: `mac/Sources/claude-board-hook/main.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/SocketProtocolTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `Decision`
- Produces:
  ```swift
  public enum BridgeSocket { public static var path: String }   // ~/.claude-board/sock
  public struct BridgeReply: Codable { public let decision: String? }   // "allow" | "deny" | nil
  public enum HookOutput { public static func json(for decision: Decision) -> String }
  /// Hook side: send event bytes, wait for one reply line. Returns nil on any failure.
  public func bridgeRoundTrip(event: Data, waitForReply: Bool, timeout: TimeInterval) -> BridgeReply?
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// mac/Tests/ClaudeBoardCoreTests/SocketProtocolTests.swift
import Foundation
import Testing
@testable import ClaudeBoardCore

@Test func allowJsonMatchesClaudeCodeSchema() throws {
    let obj = try JSONSerialization.jsonObject(with: Data(HookOutput.json(for: .allow).utf8)) as! [String: Any]
    let out = obj["hookSpecificOutput"] as! [String: Any]
    #expect(out["hookEventName"] as? String == "PermissionRequest")
    #expect((out["decision"] as! [String: Any])["behavior"] as? String == "allow")
}

@Test func denyJson() throws {
    #expect(HookOutput.json(for: .deny).contains(#""behavior":"deny""#))
}

@Test func noDaemonFallsThroughFast() {
    setenv("CLAUDE_BOARD_SOCK", "/tmp/claude-board-test-missing.sock", 1)
    let start = Date()
    let reply = bridgeRoundTrip(event: Data("{}".utf8), waitForReply: true, timeout: 5)
    #expect(reply == nil)
    #expect(Date().timeIntervalSince(start) < 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac && swift test --filter SocketProtocol`
Expected: compile errors.

- [ ] **Step 3: Implement the protocol helpers**

```swift
// mac/Sources/ClaudeBoardCore/SocketProtocol.swift
import Foundation

public enum BridgeSocket {
    public static var path: String {
        ProcessInfo.processInfo.environment["CLAUDE_BOARD_SOCK"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-board/sock")
    }
}

/// Daemon → hook, one JSON line
public struct BridgeReply: Codable, Equatable, Sendable {
    public let decision: String?
    public init(decision: String?) { self.decision = decision }
}

public enum HookOutput {
    public static func json(for decision: Decision) -> String {
        let behavior = decision == .allow ? "allow" : "deny"
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\#(behavior)"}}}"#
    }
}

/// Hook side. Writes the event followed by "\n"; if `waitForReply`, reads one line back.
/// Any failure (no daemon, timeout, garbage) returns nil so the caller can fall through.
public func bridgeRoundTrip(event: Data, waitForReply: Bool, timeout: TimeInterval) -> BridgeReply? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = BridgeSocket.path
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: path.utf8)
        buf[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var payload = event
    payload.append(0x0a)
    let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == payload.count, waitForReply else { return nil }

    var line = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0a { break }
        line.append(byte)
    }
    return try? JSONDecoder().decode(BridgeReply.self, from: line)
}
```

- [ ] **Step 4: Implement the hook CLI**

```swift
// mac/Sources/claude-board-hook/main.swift
// Claude Code hook: forwards the event to the claude-board daemon.
// PermissionRequest: prints the board's decision, or nothing (Claude shows its normal prompt).
import ClaudeBoardCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? HookEvent.parse(input) else { exit(0) }

let isPermission = event.name == "PermissionRequest"
let reply = bridgeRoundTrip(event: input, waitForReply: isPermission, timeout: 92)

if isPermission, let raw = reply?.decision, let decision = raw == "allow" ? Decision.allow : raw == "deny" ? .deny : nil {
    print(HookOutput.json(for: decision))
}
exit(0)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mac && swift test && swift build -c release`
Expected: all tests pass; release build succeeds.

- [ ] **Step 6: Manual check — hook falls through with no daemon**

Run: `echo '{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}' | CLAUDE_BOARD_SOCK=/tmp/none.sock mac/.build/release/claude-board-hook; echo "exit=$?"`
Expected: no output, `exit=0`, returns immediately.

- [ ] **Step 7: Commit**

```bash
git add mac
git commit -m "mac: claude-board-hook CLI and hook/daemon socket protocol"
```

---

### Task 4: Firmware — Claude protocol, two connections, Claude BLE service

**Files:**
- Create: `firmware/main/claude_proto.c`, `firmware/main/claude_proto.h`, `firmware/test/test_claude_proto.c`, `firmware/test/claude_ble_test.py`
- Modify: `firmware/main/ble_link.c`, `firmware/main/app.h`, `firmware/main/main.c`, `firmware/main/CMakeLists.txt`, `firmware/sdkconfig.defaults`

**Interfaces:**
- Consumes: wire format from Task 1 (`[flags][kind][id u32 LE][utf8]`, answer `[id u32 LE][decision]`)
- Produces (C):
  ```c
  typedef enum { CLAUDE_PERMISSION = 0, CLAUDE_FINISHED = 1, CLAUDE_CANCEL = 2 } claude_kind_t;
  typedef struct { claude_kind_t kind; uint32_t id; char text[CLAUDE_TEXT_MAX + 1]; } claude_msg_t;
  typedef struct { uint8_t buf[CLAUDE_TEXT_MAX + 5]; size_t len; } claude_rx_t;
  /* Feeds one BLE write. Returns true and fills *out when a complete message has arrived. */
  bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out);
  void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5]);
  /* ble_link.c */
  bool ble_link_claude_connected(void);
  bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);   /* 1 allow, 2 deny */
  /* app.h, implemented in Task 5 (temporary log-only stubs in this task) */
  void app_on_claude_message(const claude_msg_t *msg);
  void app_on_claude_link(bool connected);
  ```
- Connection roles: a connection becomes the **iPhone** when it subscribes to the audio characteristic, and the **Mac** when it subscribes to the Claude answer characteristic. `app_on_connection_changed(bool)` now means "iPhone translation link up/down" and is called on audio subscribe/unsubscribe/disconnect, not on raw connect.

- [ ] **Step 1: Write the failing host test**

```c
// firmware/test/test_claude_proto.c — build: cc -I../main -o /tmp/t test_claude_proto.c ../main/claude_proto.c && /tmp/t
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "claude_proto.h"

static void single_chunk_permission(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t c[] = { 0x03, 0, 0x04, 0x03, 0x02, 0x01, 'p', '\n', 'B', 'a', 's', 'h', '\n', 'l', 's' };
    assert(claude_rx_feed(&rx, c, sizeof c, &m));
    assert(m.kind == CLAUDE_PERMISSION && m.id == 0x01020304);
    assert(strcmp(m.text, "p\nBash\nls") == 0);
}

static void chunked_utf8_roundtrip(void)
{
    const char *text = "dự án\nBash\nrm -rf thư mục cũ";
    uint8_t msg[128] = { 0, 7, 0, 0, 0 };
    size_t n = 5 + strlen(text);
    memcpy(msg + 5, text, strlen(text));
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    bool done = false;
    for (size_t off = 0; off < n; off += 6) {
        uint8_t chunk[7];
        size_t len = n - off < 6 ? n - off : 6;
        chunk[0] = (off == 0 ? 1 : 0) | (off + len == n ? 2 : 0);
        memcpy(chunk + 1, msg + off, len);
        done = claude_rx_feed(&rx, chunk, len + 1, &m);
        assert(done == (off + len == n));
    }
    assert(m.id == 7 && strcmp(m.text, text) == 0);
}

static void first_chunk_resets_partial(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t stale[] = { 0x01, 0, 1, 0, 0, 0, 'x', 'x' };
    assert(!claude_rx_feed(&rx, stale, sizeof stale, &m));
    uint8_t fresh[] = { 0x03, 2, 9, 0, 0, 0 };
    assert(claude_rx_feed(&rx, fresh, sizeof fresh, &m));
    assert(m.kind == CLAUDE_CANCEL && m.id == 9 && m.text[0] == 0);
}

static void cancel_clears_pending(void)
{
    /* cancel parses with empty text; the UI test in Task 5 checks it clears the shown request */
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t c[] = { 0x03, 2, 0x10, 0, 0, 0 };
    assert(claude_rx_feed(&rx, c, sizeof c, &m) && m.kind == CLAUDE_CANCEL && m.id == 0x10);
}

static void overflow_is_truncated_not_crashing(void)
{
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t head[] = { 0x01, 0, 1, 0, 0, 0 };
    claude_rx_feed(&rx, head, sizeof head, &m);
    uint8_t big[201];
    memset(big, 'a', sizeof big);
    big[0] = 0;
    for (int i = 0; i < 10; i++) {
        claude_rx_feed(&rx, big, sizeof big, &m);
    }
    uint8_t tail[] = { 0x02, 'z' };
    assert(claude_rx_feed(&rx, tail, sizeof tail, &m));
    assert(strlen(m.text) == CLAUDE_TEXT_MAX);
}

static void answer_encoding(void)
{
    uint8_t out[5];
    claude_encode_answer(0x01020304, 1, out);
    uint8_t want[5] = { 0x04, 0x03, 0x02, 0x01, 1 };
    assert(memcmp(out, want, 5) == 0);
}

int main(void)
{
    single_chunk_permission();
    chunked_utf8_roundtrip();
    first_chunk_resets_partial();
    cancel_clears_pending();
    overflow_is_truncated_not_crashing();
    answer_encoding();
    puts("claude_proto: all tests passed");
    return 0;
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd firmware/test && cc -I../main -o /tmp/t test_claude_proto.c ../main/claude_proto.c && /tmp/t`
Expected: compile error (`claude_proto.h` missing).

- [ ] **Step 3: Implement `claude_proto`**

```c
// firmware/main/claude_proto.h
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_TEXT_MAX 400

typedef enum { CLAUDE_PERMISSION = 0, CLAUDE_FINISHED = 1, CLAUDE_CANCEL = 2 } claude_kind_t;

typedef struct {
    claude_kind_t kind;
    uint32_t id;
    char text[CLAUDE_TEXT_MAX + 1];
} claude_msg_t;

typedef struct {
    uint8_t buf[CLAUDE_TEXT_MAX + 5];
    size_t len;
} claude_rx_t;

/* Feeds one BLE write ([flags][payload...]). Returns true and fills *out when the last chunk arrives. */
bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out);
void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5]);
```

```c
// firmware/main/claude_proto.c
#include "claude_proto.h"
#include <string.h>

#define FLAG_FIRST 0x01
#define FLAG_LAST  0x02

/* Cuts at the last complete UTF-8 sequence so truncated text never ends mid-character */
static size_t utf8_safe_len(const uint8_t *s, size_t n)
{
    size_t i = n;
    while (i > 0 && (s[i - 1] & 0xC0) == 0x80) {
        i--;
    }
    if (i > 0 && (s[i - 1] & 0x80)) {
        uint8_t lead = s[i - 1];
        size_t need = (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
        if (n - (i - 1) < need) {
            return i - 1;
        }
    }
    return n;
}

bool claude_rx_feed(claude_rx_t *rx, const uint8_t *chunk, size_t len, claude_msg_t *out)
{
    if (len < 1) {
        return false;
    }
    uint8_t flags = chunk[0];
    if (flags & FLAG_FIRST) {
        rx->len = 0;
    }
    size_t n = len - 1;
    if (rx->len + n > sizeof(rx->buf)) {
        n = sizeof(rx->buf) - rx->len;
    }
    memcpy(rx->buf + rx->len, chunk + 1, n);
    rx->len += n;

    if (!(flags & FLAG_LAST) || rx->len < 5) {
        return false;
    }
    out->kind = (claude_kind_t)rx->buf[0];
    out->id = (uint32_t)rx->buf[1] | (uint32_t)rx->buf[2] << 8 | (uint32_t)rx->buf[3] << 16 | (uint32_t)rx->buf[4] << 24;
    size_t text_len = utf8_safe_len(rx->buf + 5, rx->len - 5);
    memcpy(out->text, rx->buf + 5, text_len);
    out->text[text_len] = '\0';
    rx->len = 0;
    return true;
}

void claude_encode_answer(uint32_t id, uint8_t decision, uint8_t out[5])
{
    out[0] = id & 0xff;
    out[1] = (id >> 8) & 0xff;
    out[2] = (id >> 16) & 0xff;
    out[3] = (id >> 24) & 0xff;
    out[4] = decision;
}
```

- [ ] **Step 4: Run host tests**

Run: `cd firmware/test && cc -Wall -I../main -o /tmp/t test_claude_proto.c ../main/claude_proto.c && /tmp/t`
Expected: `claude_proto: all tests passed`

- [ ] **Step 5: Two connections and connection roles in `ble_link.c`**

Replace the single `s_conn_handle` / `s_audio_subscribed` with roles:

```c
/* ble_link.c — replaces s_conn_handle and s_audio_subscribed */
static uint16_t s_phone_conn = BLE_HS_CONN_HANDLE_NONE;   /* subscribed to audio */
static uint16_t s_mac_conn = BLE_HS_CONN_HANDLE_NONE;     /* subscribed to Claude answers */
static int s_connections;

static uint16_t s_claude_req_handle;
static uint16_t s_claude_ans_handle;
static claude_rx_t s_claude_rx;

static const ble_uuid128_t s_claude_svc_uuid = SVC_UUID(0x10);
static const ble_uuid128_t s_claude_req_uuid = SVC_UUID(0x11);
static const ble_uuid128_t s_claude_ans_uuid = SVC_UUID(0x12);
```

Add the service to `s_services` (before the terminating `{ 0 }`):

```c
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_claude_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_claude_req_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_claude_req_handle,
            },
            {
                .uuid = &s_claude_ans_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_claude_ans_handle,
            },
            { 0 },
        },
    },
```

In `chr_access`, before the final `return BLE_ATT_ERR_UNLIKELY;`:

```c
    } else if (attr_handle == s_claude_req_handle && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        static claude_msg_t msg;
        if (claude_rx_feed(&s_claude_rx, buf, len, &msg)) {
            app_on_claude_message(&msg);
        }
        return 0;
```

Rewrite the GAP handler cases:

```c
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            start_advertising();
            break;
        }
        s_connections++;
        ESP_LOGI(TAG, "connected (%d link%s)", s_connections, s_connections > 1 ? "s" : "");
        ble_gap_set_prefered_le_phy(event->connect.conn_handle, BLE_GAP_LE_PHY_2M_MASK,
                                    BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_CODED_ANY);
        struct ble_gap_upd_params params = {
            .itvl_min = 24,   /* 30 ms: two 20 ms audio packets per event, half the radio wake-ups of 15 ms */
            .itvl_max = 36,   /* 45 ms */
            .latency = 0,
            .supervision_timeout = 400,
        };
        ble_gap_update_params(event->connect.conn_handle, &params);
        if (s_connections < CONFIG_BT_NIMBLE_MAX_CONNECTIONS) {
            start_advertising();   /* keep the second slot open (iPhone + Mac) */
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        s_connections--;
        ESP_LOGI(TAG, "disconnected, reason 0x%x", event->disconnect.reason);
        if (event->disconnect.conn.conn_handle == s_phone_conn) {
            s_phone_conn = BLE_HS_CONN_HANDLE_NONE;
            app_on_connection_changed(false);
        }
        if (event->disconnect.conn.conn_handle == s_mac_conn) {
            s_mac_conn = BLE_HS_CONN_HANDLE_NONE;
            s_claude_rx.len = 0;
            app_on_claude_link(false);
        }
        start_advertising();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_audio_handle) {
            bool on = event->subscribe.cur_notify;
            s_phone_conn = on ? event->subscribe.conn_handle : BLE_HS_CONN_HANDLE_NONE;
            ESP_LOGI(TAG, "iPhone audio %s", on ? "on" : "off");
            app_on_connection_changed(on);
        } else if (event->subscribe.attr_handle == s_claude_ans_handle) {
            bool on = event->subscribe.cur_notify;
            s_mac_conn = on ? event->subscribe.conn_handle : BLE_HS_CONN_HANDLE_NONE;
            ESP_LOGI(TAG, "Mac Claude link %s", on ? "on" : "off");
            app_on_claude_link(on);
        }
        break;
```

Update the accessors to use the roles:

```c
bool ble_link_audio_ready(void) { return s_phone_conn != BLE_HS_CONN_HANDLE_NONE; }

uint16_t ble_link_payload_max(void)
{
    return s_phone_conn == BLE_HS_CONN_HANDLE_NONE ? 20 : ble_att_mtu(s_phone_conn) - 3;
}

bool ble_link_claude_connected(void) { return s_mac_conn != BLE_HS_CONN_HANDLE_NONE; }

bool ble_link_send_claude_answer(uint32_t id, uint8_t decision)
{
    if (s_mac_conn == BLE_HS_CONN_HANDLE_NONE) {
        return false;
    }
    uint8_t payload[5];
    claude_encode_answer(id, decision, payload);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(payload, sizeof(payload));
    return om && ble_gatts_notify_custom(s_mac_conn, s_claude_ans_handle, om) == 0;
}
```

In `ble_link_send_audio` and `ble_link_notify_control`, replace `s_conn_handle` with `s_phone_conn`.
Add `#include "claude_proto.h"` to `ble_link.c`; add `"claude_proto.c"` to `firmware/main/CMakeLists.txt` SRCS; set `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2` in `firmware/sdkconfig.defaults`.

- [ ] **Step 6: App hooks + sleep rule (temporary stubs until Task 5)**

In `app.h` add:

```c
#include "claude_proto.h"
/* ble_link.c */
bool ble_link_claude_connected(void);
bool ble_link_send_claude_answer(uint32_t id, uint8_t decision);
/* main.c */
void app_on_claude_message(const claude_msg_t *msg);
void app_on_claude_link(bool connected);
```

In `main.c`:

```c
static volatile bool s_claude_link;

void app_on_claude_link(bool connected)
{
    s_claude_link = connected;
    ESP_LOGI(TAG, "Claude link %s", connected ? "up" : "down");
    ui_mark_activity();
}

void app_on_claude_message(const claude_msg_t *msg)
{
    ESP_LOGI(TAG, "claude msg kind=%d id=%lu text=\"%s\"", msg->kind, (unsigned long)msg->id, msg->text);
}
```

Change the deep-sleep condition so a Mac link alone keeps the board awake:

```c
            if (!s_connected && !s_claude_link && s_disconnected_since != 0 &&
                    esp_timer_get_time() - s_disconnected_since > SLEEP_AFTER_DISCONNECT_US) {
```

and in `app_on_claude_link`, when `connected == false && !s_connected`, set `s_disconnected_since = esp_timer_get_time();`.

- [ ] **Step 7: BLE test script acting as the Mac**

```python
# firmware/test/claude_ble_test.py — run with the iPhone app closed or open (board takes 2 links)
import asyncio, struct, sys
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS = "a7c00011" + B, "a7c00012" + B

def message(kind, mid, text):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()

def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        answers = asyncio.Queue()
        await c.start_notify(ANS, lambda _, d: answers.put_nowait(struct.unpack("<IB", bytes(d))))
        mid = 4242
        for ch in chunks(message(0, mid, "esp32-translator\nBash\nnpm test -- --watch=false"), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
        print("Request shown on the board: tap", sys.argv[1] if len(sys.argv) > 1 else "Allow or Deny")
        got = await asyncio.wait_for(answers.get(), 60)
        print("answer:", got)
        assert got[0] == mid and got[1] in (1, 2)
        for ch in chunks(message(1, mid + 1, "esp32-translator\nAll tests passed."), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
        print("finished message sent")

asyncio.run(main())
```

- [ ] **Step 8: Build, flash, verify the protocol path with logs**

Run:
```bash
. ~/esp/esp-idf/export.sh && cd firmware && rm -f sdkconfig && idf.py build flash
```
Then, in another terminal, `idf.py monitor` (or the repo's serial logger) and run `python firmware/test/claude_ble_test.py`.
Expected in the board log: `Mac Claude link on`, then `claude msg kind=0 id=4242 text="esp32-translator\nBash\nnpm test -- --watch=false"`. With the iPhone app open at the same time, the log shows `connected (2 links)` and translation keeps streaming (`audio: ... sent` keeps increasing while someone talks). The script times out waiting for an answer (no UI yet), which is expected in this task.

- [ ] **Step 9: Commit**

```bash
git add firmware
git commit -m "firmware: Claude BLE service, two connections with roles, host-tested protocol"
```

---

### Task 5: Firmware — Claude screen, mode switch, chime

**Files:**
- Create: `firmware/main/claude_ui.c`, `firmware/main/chime.c`
- Modify: `firmware/main/app.h`, `firmware/main/main.c`, `firmware/main/ui.c`, `firmware/main/CMakeLists.txt`

**Interfaces:**
- Consumes: `claude_msg_t`, `ble_link_send_claude_answer`, `ble_link_claude_connected` (Task 4); `ui_mark_activity`, `lock()/unlock()` pattern from `ui.c`
- Produces:
  ```c
  void claude_ui_init(void);                         /* builds the screen (not loaded) */
  void claude_ui_show(bool show);                    /* load Claude or translator screen */
  bool claude_ui_visible(void);
  void claude_ui_on_message(const claude_msg_t *m);  /* takes the display lock */
  void claude_ui_set_link(bool connected);
  void chime_play(chime_t kind);                     /* CHIME_REQUEST, CHIME_DONE; non-blocking */
  /* ui.c */
  lv_obj_t *ui_translator_screen(void);
  void ui_force_screen_on(void);                     /* also clears a double-tap screen-off */
  void ui_attach_screen_gestures(lv_obj_t *screen);  /* double-tap toggle on any screen */
  ```

- [ ] **Step 1: Expose translator screen + gestures in `ui.c`**

In `ui_init()`, keep a handle `static lv_obj_t *s_translator_scr = scr;` and move `lv_obj_add_event_cb(scr, on_double_tap, LV_EVENT_DOUBLE_CLICKED, NULL);` into:

```c
void ui_attach_screen_gestures(lv_obj_t *screen)
{
    lv_obj_add_event_cb(screen, on_double_tap, LV_EVENT_DOUBLE_CLICKED, NULL);
}

lv_obj_t *ui_translator_screen(void) { return s_translator_scr; }

void ui_force_screen_on(void)
{
    s_manual_off = false;
    ui_mark_activity();
}
```

and call `ui_attach_screen_gestures(scr)` from `ui_init()`. Declare all three in `app.h`.

- [ ] **Step 2: Claude screen**

```c
// firmware/main/claude_ui.c
/*
 * Claude companion screen:
 *   top    : "Claude" + link state
 *   middle : project (grey), tool (bold), one-line summary
 *   bottom : Deny / Allow while a permission request is pending
 * Requests arrive one at a time from the Mac (the daemon queues the rest).
 */
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "lvgl.h"

#include "app.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "claude_ui";

static lv_obj_t *s_scr;
static lv_obj_t *s_status;
static lv_obj_t *s_project;
static lv_obj_t *s_title;
static lv_obj_t *s_detail;
static lv_obj_t *s_allow;
static lv_obj_t *s_deny;
static uint32_t s_pending_id;   /* 0 = none */
static bool s_link;

static void set_buttons(bool visible)
{
    if (visible) {
        lv_obj_remove_flag(s_allow, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_deny, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_allow, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_deny, LV_OBJ_FLAG_HIDDEN);
    }
}

static void show_idle(const char *title, const char *detail)
{
    s_pending_id = 0;
    set_buttons(false);
    lv_label_set_text(s_project, "");
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_detail, detail);
}

/* Runs in the LVGL task (lock already held) */
static void on_answer(lv_event_t *e)
{
    uint8_t decision = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
    if (s_pending_id == 0) {
        return;
    }
    bool sent = ble_link_send_claude_answer(s_pending_id, decision);
    ESP_LOGI(TAG, "answer %s for %lu (%s)", decision == 1 ? "allow" : "deny",
             (unsigned long)s_pending_id, sent ? "sent" : "NOT sent");
    show_idle(decision == 1 ? "Allowed" : "Denied", sent ? "Claude continues." : "Mac not connected.");
}

static lv_obj_t *make_button(const char *text, uint32_t color, int x, uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, 150, 64);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, -60);
    lv_obj_set_style_radius(b, 32, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_answer, LV_EVENT_CLICKED, (void *)(uintptr_t)decision);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}

static lv_obj_t *make_label(const lv_font_t *font, uint32_t color, int width, int y)
{
    lv_obj_t *l = lv_label_create(s_scr);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    return l;
}

void claude_ui_init(void)
{
    bsp_display_lock((uint32_t)-1);
    s_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(s_scr, lv_color_black(), 0);
    lv_obj_remove_flag(s_scr, LV_OBJ_FLAG_SCROLLABLE);
    ui_attach_screen_gestures(s_scr);

    s_status = make_label(&font_vi_22, 0xc8c8c8, 300, 48);
    s_project = make_label(&font_vi_22, 0x9a9a9a, 360, 110);
    s_title = make_label(&font_vi_36, 0xffffff, 380, 146);
    s_detail = make_label(&font_vi_22, 0xffffff, 380, 200);
    lv_obj_set_height(s_detail, 120);
    lv_label_set_long_mode(s_detail, LV_LABEL_LONG_MODE_DOTS);

    s_deny = make_button("Deny", 0x8a1c1c, -80, 2);
    s_allow = make_button("Allow", 0x1f9d55, 80, 1);

    lv_label_set_text(s_status, "Claude · Mac not connected");
    show_idle("No requests", "Claude Code permission\nprompts will appear here.");
    bsp_display_unlock();
}

void claude_ui_show(bool show)
{
    bsp_display_lock((uint32_t)-1);
    lv_screen_load(show ? s_scr : ui_translator_screen());
    bsp_display_unlock();
}

bool claude_ui_visible(void)
{
    return lv_screen_active() == s_scr;
}

void claude_ui_set_link(bool connected)
{
    s_link = connected;
    bsp_display_lock((uint32_t)-1);
    lv_label_set_text(s_status, connected ? "Claude · Mac connected" : "Claude · Mac not connected");
    if (!connected && s_pending_id) {
        show_idle("No requests", "Mac disconnected.\nAnswer in the terminal.");
    }
    bsp_display_unlock();
}

void claude_ui_on_message(const claude_msg_t *m)
{
    /* text: permission "project\ntool\nsummary", finished "project\nline" */
    char text[CLAUDE_TEXT_MAX + 1];
    strncpy(text, m->text, sizeof(text));
    text[CLAUDE_TEXT_MAX] = '\0';
    char *project = text;
    char *second = strchr(project, '\n');
    if (second) {
        *second++ = '\0';
    }
    char *third = second ? strchr(second, '\n') : NULL;
    if (third) {
        *third++ = '\0';
    }

    bsp_display_lock((uint32_t)-1);
    switch (m->kind) {
    case CLAUDE_PERMISSION:
        s_pending_id = m->id;
        lv_label_set_text(s_project, project);
        lv_label_set_text(s_title, second ? second : "Permission");
        lv_label_set_text(s_detail, third ? third : "");
        set_buttons(true);
        break;
    case CLAUDE_CANCEL:
        if (m->id == s_pending_id) {
            show_idle("No requests", "Answered in the terminal\nor timed out.");
        }
        break;
    case CLAUDE_FINISHED:
        if (s_pending_id == 0) {
            lv_label_set_text(s_project, project);
            lv_label_set_text(s_title, "Claude finished");
            lv_label_set_text(s_detail, second ? second : "");
        }
        break;
    }
    bsp_display_unlock();
}
```

- [ ] **Step 3: Chime**

```c
// firmware/main/chime.c
/*
 * Short two-tone chime on the ES8311 speaker, generated on the fly.
 * The I2S bus is shared with the mics (duplex, 16 kHz stereo), so the speaker is opened with the same format.
 */
#include <math.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "app.h"

#define RATE 16000

static QueueHandle_t s_queue;

static void tone(esp_codec_dev_handle_t spk, float freq, int ms)
{
    static int16_t buf[RATE / 100 * 2];   /* 10 ms stereo */
    int blocks = ms / 10;
    for (int b = 0; b < blocks; b++) {
        for (int i = 0; i < RATE / 100; i++) {
            int n = b * (RATE / 100) + i;
            float env = fminf(1.0f, fminf(n / 160.0f, (blocks * RATE / 100 - n) / 480.0f));
            int16_t s = (int16_t)(sinf(2 * (float)M_PI * freq * n / RATE) * 9000 * env);
            buf[2 * i] = buf[2 * i + 1] = s;
        }
        esp_codec_dev_write(spk, buf, sizeof(buf));
    }
}

static void chime_task(void *arg)
{
    esp_codec_dev_handle_t spk = bsp_audio_codec_speaker_init();
    if (!spk) {
        ESP_LOGW("chime", "speaker unavailable");
        vTaskDelete(NULL);
        return;
    }
    chime_t kind;
    while (xQueueReceive(s_queue, &kind, portMAX_DELAY) == pdTRUE) {
        esp_codec_dev_sample_info_t fs = { .sample_rate = RATE, .channel = 2, .bits_per_sample = 16 };
        if (esp_codec_dev_open(spk, &fs) != ESP_CODEC_DEV_OK) {
            continue;
        }
        esp_codec_dev_set_out_vol(spk, 70);
        if (kind == CHIME_REQUEST) {
            tone(spk, 880, 120);
            tone(spk, 1320, 160);
        } else {
            tone(spk, 1320, 120);
            tone(spk, 990, 160);
        }
        esp_codec_dev_close(spk);
    }
}

void chime_start(void)
{
    s_queue = xQueueCreate(4, sizeof(chime_t));
    xTaskCreate(chime_task, "chime", 4096, NULL, 3, NULL);
}

void chime_play(chime_t kind)
{
    if (s_queue) {
        xQueueSend(s_queue, &kind, 0);
    }
}
```

In `app.h`: `typedef enum { CHIME_REQUEST, CHIME_DONE } chime_t; void chime_start(void); void chime_play(chime_t kind);` plus the `claude_ui_*` declarations. Add `"claude_ui.c" "chime.c"` to CMakeLists SRCS.

- [ ] **Step 4: Wire it in `main.c`**

Replace the Task 4 stubs and the mode placeholder:

```c
void app_switch_mode(void)
{
    claude_ui_show(!claude_ui_visible());
}

void app_on_claude_link(bool connected)
{
    s_claude_link = connected;
    if (!connected && !s_connected) {
        s_disconnected_since = esp_timer_get_time();
    }
    claude_ui_set_link(connected);
    ui_mark_activity();
}

void app_on_claude_message(const claude_msg_t *msg)
{
    ESP_LOGI(TAG, "claude msg kind=%d id=%lu", msg->kind, (unsigned long)msg->id);
    claude_ui_on_message(msg);
    if (msg->kind == CLAUDE_PERMISSION) {
        claude_ui_show(true);        /* a request always takes over the screen */
        ui_force_screen_on();
        chime_play(CHIME_REQUEST);
    } else if (msg->kind == CLAUDE_FINISHED) {
        ui_toast("Claude finished", 3000);
        chime_play(CHIME_DONE);
    }
}
```

In `app_main`, after `ui_init();` add `claude_ui_init();`; after `pmu_start();` add `chime_start();`.

- [ ] **Step 5: Build, flash, verify on the device with the test script**

Run: `idf.py build flash`, then `python firmware/test/claude_ble_test.py Allow`.
Expected:
- The board switches to the Claude screen, plays the request chime, shows `esp32-translator` / `Bash` / `npm test -- --watch=false` with Deny/Allow.
- Tapping **Allow** prints `answer: (4242, 1)` in the script; the screen shows "Allowed".
- The script then sends a finished message: chime + "Claude finished" toast.
- Repeat with **Deny** → `answer: (4242, 2)`.
- Double-tap the screen off, run the script again: the request turns the screen back on.
- PWR double press toggles Translator ↔ Claude screens; translation subtitles still update when you go back.

- [ ] **Step 6: Commit**

```bash
git add firmware
git commit -m "firmware: Claude screen with Allow/Deny, mode switch, chime"
```

---

### Task 6: `claude-board` daemon (socket server + CoreBluetooth)

**Files:**
- Create: `mac/Sources/claude-board/BoardLink.swift`
- Replace: `mac/Sources/claude-board/main.swift`

**Interfaces:**
- Consumes: `RequestQueue`, `BoardMessage`, `Answer`, `HookEvent`, `Summary`, `BridgeSocket`, `BridgeReply` (Tasks 1–3)
- Produces: the `claude-board` executable: listens on `BridgeSocket.path`, logs to stderr.

- [ ] **Step 1: BLE link**

```swift
// mac/Sources/claude-board/BoardLink.swift
import ClaudeBoardCore
import CoreBluetooth
import Foundation

/// Connects to the translator board (it advertises the translator service) and talks to its Claude service.
final class BoardLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let translatorService = CBUUID(string: "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeService = CBUUID(string: "A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let requestChar = CBUUID(string: "A7C00011-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let answerChar = CBUUID(string: "A7C00012-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    var onAnswer: (@Sendable (Answer) -> Void)?
    var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "claude-board.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var request: CBCharacteristic?
    private let knownKey = "boardIdentifier"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    var isReady: Bool { queue.sync { request != nil } }

    func send(_ message: BoardMessage) {
        queue.async { [self] in
            guard let peripheral, let request else { return }
            let size = peripheral.maximumWriteValueLength(for: .withResponse)
            for chunk in BoardMessage.chunks(message.encode(), maxChunk: size) {
                peripheral.writeValue(chunk, for: request, type: .withResponse)
            }
        }
    }

    private func log(_ s: String) { FileHandle.standardError.write(Data("[ble] \(s)\n".utf8)) }

    private func scan() {
        if let id = UserDefaults.standard.string(forKey: knownKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: [Self.translatorService])
            log("scanning")
        }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { scan() } else { log("bluetooth state \(c.state.rawValue)") }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected \(p.identifier)")
        p.discoverServices([Self.claudeService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        queue.asyncAfter(deadline: .now() + 2) { self.scan() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        request = nil
        log("disconnected")
        onConnectionChange?(false)
        queue.asyncAfter(deadline: .now() + 2) { self.scan() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.claudeService }) else {
            log("board has no Claude service (old firmware?)")
            return
        }
        p.discoverCharacteristics([Self.requestChar, Self.answerChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == Self.requestChar { request = c }
            if c.uuid == Self.answerChar { p.setNotifyValue(true, for: c) }
        }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: knownKey)
        log("ready")
        onConnectionChange?(true)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == Self.answerChar, let v = c.value, let a = Answer.decode(v) { onAnswer?(a) }
    }
}
```

- [ ] **Step 2: Daemon main**

```swift
// mac/Sources/claude-board/main.swift
// claude-board: bridges Claude Code hooks (Unix socket) to the ESP32 board (BLE).
import ClaudeBoardCore
import Foundation
import Network

func log(_ s: String) { FileHandle.standardError.write(Data("[claude-board] \(s)\n".utf8)) }

let board = BoardLink()
let requests = RequestQueue(send: { board.send($0) })
board.onAnswer = { a in Task { await requests.handle(a) } }
board.onConnectionChange = { up in if !up { Task { await requests.boardDisconnected() } } }

// Socket: ~/.claude-board/sock, owner-only
let path = BridgeSocket.path
try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
unlink(path)
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
let listener = try NWListener(using: params)

/// Last line of Claude's reply for the "finished" message
func lastLine(_ e: HookEvent) -> String {
    if let m = e.lastAssistantMessage { return Summary.trim(m.split(whereSeparator: \.isNewline).last.map(String.init) ?? "", maxChars: 140) }
    guard let p = e.transcriptPath, let text = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
    for line in text.split(separator: "\n").reversed() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]],
              let t = content.compactMap({ $0["text"] as? String }).last else { continue }
        return Summary.trim(t.split(whereSeparator: \.isNewline).last.map(String.init) ?? t, maxChars: 140)
    }
    return ""
}

func handle(_ conn: NWConnection) {
    conn.start(queue: .global())
    var buffer = Data()
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data { buffer.append(data) }
            if let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                Task { await process(Data(line), conn) }
            } else if !done && error == nil {
                receive()
            } else {
                conn.cancel()
            }
        }
    }
    receive()
}

func process(_ line: Data, _ conn: NWConnection) async {
    guard let e = try? HookEvent.parse(line) else { conn.cancel(); return }
    let project = Summary.project(cwd: e.cwd)
    switch e.name {
    case "PermissionRequest":
        guard board.isReady else { reply(nil, conn); return }
        // If the hook goes away (user answered in the terminal), cancel the board request
        let ask = Task { await requests.ask(project: project, tool: e.toolName ?? "Tool", summary: Summary.permission(e)) }
        conn.stateUpdateHandler = { state in
            if case .cancelled = state { ask.cancel() }
            if case .failed = state { ask.cancel() }
        }
        let d = await ask.value
        log("\(project) \(e.toolName ?? "") → \(d.map { $0 == .allow ? "allow" : "deny" } ?? "fall through")")
        reply(d, conn)
    case "Stop", "Notification":
        if board.isReady {
            let text = e.name == "Stop" ? lastLine(e) : "Claude is waiting for you"
            await requests.notifyFinished(project: project, line: text)
        }
        conn.cancel()
    default:
        conn.cancel()
    }
}

func reply(_ d: Decision?, _ conn: NWConnection) {
    let r = BridgeReply(decision: d.map { $0 == .allow ? "allow" : "deny" })
    var data = (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
    data.append(0x0a)
    conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
}

listener.newConnectionHandler = handle
listener.stateUpdateHandler = { s in
    if case .ready = s { chmod(path, 0o600); log("listening on \(path)") }
    if case .failed(let e) = s { log("listener failed: \(e)"); exit(1) }
}
listener.start(queue: .main)
dispatchMain()
```

- [ ] **Step 3: Build**

Run: `cd mac && swift build -c release`
Expected: success.

- [ ] **Step 4: End-to-end with the real board, no Claude yet**

Run in one terminal: `mac/.build/release/claude-board` (macOS asks for Bluetooth permission the first time → allow).
Expected log: `[ble] connected …`, `[ble] ready`, `listening on ~/.claude-board/sock`.
In another terminal:
```bash
echo '{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"'$PWD'","tool_name":"Bash","tool_input":{"command":"git push"}}' | mac/.build/release/claude-board-hook
```
Expected: the board shows `esp32-translator / Bash / git push`. Tap Allow → the command prints the allow JSON. Run again, tap Deny → deny JSON. Run again and press Ctrl-C in the hook terminal before tapping → the board shows "Answered in the terminal or timed out."

- [ ] **Step 5: Commit**

```bash
git add mac
git commit -m "mac: claude-board daemon (Unix socket + CoreBluetooth)"
```

---

### Task 7: Install script, Claude Code hooks, README, real-session test

**Files:**
- Create: `mac/install.sh`, `mac/dev.cicca.claude-board.plist.template`
- Modify: `README.md`

- [ ] **Step 1: launchd template**

```xml
<!-- mac/dev.cicca.claude-board.plist.template -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.cicca.claude-board</string>
  <key>ProgramArguments</key><array><string>__BIN__/claude-board</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>__HOME__/.claude-board/daemon.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Install script (backs up settings.json, merges hooks idempotently)**

```bash
#!/bin/bash
# mac/install.sh — build and install the Claude board bridge for the current user
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$HOME/.claude-board/bin"
mkdir -p "$BIN"
cp .build/release/claude-board .build/release/claude-board-hook "$BIN/"

PLIST="$HOME/Library/LaunchAgents/dev.cicca.claude-board.plist"
sed -e "s#__BIN__#$BIN#g" -e "s#__HOME__#$HOME#g" dev.cicca.claude-board.plist.template > "$PLIST"
launchctl bootout "gui/$(id -u)/dev.cicca.claude-board" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
HOOK="$BIN/claude-board-hook" python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]; hook = os.environ["HOOK"]
s = json.load(open(path))
hooks = s.setdefault("hooks", {})
def ensure(event, entry):
    lst = hooks.setdefault(event, [])
    lst[:] = [e for e in lst if not any(h.get("command", "").endswith("claude-board-hook") for h in e.get("hooks", []))]
    lst.append(entry)
ensure("PermissionRequest", {"matcher": "*", "hooks": [{"type": "command", "command": hook, "timeout": 100}]})
ensure("Stop", {"hooks": [{"type": "command", "command": hook, "async": True}]})
ensure("Notification", {"matcher": "idle_prompt", "hooks": [{"type": "command", "command": hook, "async": True}]})
json.dump(s, open(path, "w"), indent=2)
print("hooks installed in", path)
PY
echo "claude-board installed. Log: ~/.claude-board/daemon.log"
```

Also add `mac/uninstall.sh` that boots out the agent, removes the plist and `~/.claude-board/bin`, and removes hook entries whose command ends with `claude-board-hook` (same Python filter, without `ensure`'s append).

- [ ] **Step 3: Install and verify the agent**

Run: `bash mac/install.sh && sleep 3 && tail -5 ~/.claude-board/daemon.log`
Expected: `[ble] ready` and `listening on …/sock`. `~/.claude/settings.json` contains the three hook entries; a `.bak.*` copy exists.

- [ ] **Step 4: Real Claude Code session**

In a scratch folder, start `claude` (default permission mode) and ask it to run `git status`.
Expected: the board chimes and shows `Bash / git status`; Allow → Claude runs it; ask again with a different command, Deny → Claude reports it was denied; when Claude finishes the turn → done chime + "Claude finished" with the last line of the reply. Turn the board off: the next prompt appears in the terminal as usual within ~1 s.

- [ ] **Step 5: README section + commit**

Add a "Claude companion mode" section to `README.md`: what it does, `bash mac/install.sh`, `bash mac/uninstall.sh`, PWR double press, safety rules (never auto-approves; fall-through), and the BLE service table rows for `…0010/0011/0012`.

```bash
git add mac README.md
git commit -m "Claude companion: installer, hooks, docs"
git push
```
