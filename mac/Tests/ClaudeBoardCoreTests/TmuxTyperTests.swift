import Foundation
import Testing
@testable import ClaudeBoardCore

/// Records tmux invocations; answers display-message with `info`.
final class FakeTmux: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var info: String
    var infoStatus: Int32 = 0
    var sendStatus: [Int32] = []          // per send-keys call, default 0

    init(info: String) { self.info = info }

    var calls: [[String]] { lock.withLock { _calls } }
    var sendCalls: [[String]] { calls.filter { $0.contains("send-keys") } }

    var runner: TmuxTyper.Runner {
        { args in
            self.lock.withLock {
                self._calls.append(args)
                if args.contains("display-message") { return (self.infoStatus, self.info) }
                return (self.sendStatus.isEmpty ? 0 : self.sendStatus.removeFirst(), "")
            }
        }
    }
}

/// Hook parent 500 (Claude Code) whose parent is the pane process 400 (zsh), then the tmux server 300.
private let target = PaneTarget(pane: "%3", socket: "/tmp/s", ancestors: [500, 400, 300])
private let liveParents: @Sendable (Int32) -> Int32? = { [500: 400, 400: 300, 300: 1][$0] }

private func typer(_ fake: FakeTmux, parentOf: @escaping @Sendable (Int32) -> Int32? = liveParents,
                   foreground: Bool = true, socketIsUsers: Bool = true) -> TmuxTyper {
    TmuxTyper(run: fake.runner, parentOf: parentOf, isForeground: { _ in foreground },
              socketIsUsers: { _ in socketIsUsers }, enterDelay: .zero)
}

private let goodInfo = "%3\t400\t0\t0\t1\t0\n"

@Test func verifiedPaneGetsTheTextThenOneEnter() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).type("chạy các bài kiểm tra", into: target) == .typed)
    #expect(fake.calls.first == ["-S", "/tmp/s", "display-message", "-p", "-t", "%3",
                                 "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_in_mode}\t#{@claude_board}\t#{pane_synchronized}"])
    #expect(fake.sendCalls == [["-S", "/tmp/s", "send-keys", "-t", "%3", "-l", "--", "chạy các bài kiểm tra"],
                               ["-S", "/tmp/s", "send-keys", "-t", "%3", "Enter"]])
}

@Test func unmarkedPaneIsRefused() async {
    let fake = FakeTmux(info: "%3\t400\t0\t0\t\t0\n")
    #expect(await typer(fake).type("x", into: target) == .failed("Open with cb for voice"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func paneOfAnotherProcessIsRefused() async {
    let fake = FakeTmux(info: "%3\t999\t0\t0\t1\t0\n")
    #expect(await typer(fake).type("x", into: target) == .failed("The pane runs another program now — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func shellLeftInThePaneIsRefused() async {
    // Claude Code (500) exited: the pane process 400 is still there, but nothing below it is this session
    let fake = FakeTmux(info: goodInfo)
    let gone: @Sendable (Int32) -> Int32? = { [400: 300, 300: 1][$0] }
    #expect(await typer(fake, parentOf: gone).type("x", into: target) == .failed("The pane runs another program now — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func copyModeIsRefused() async {
    let fake = FakeTmux(info: "%3\t400\t0\t1\t1\t0\n")
    #expect(await typer(fake).type("x", into: target) == .failed("The terminal is in copy mode — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func deadOrMissingPaneIsRefused() async {
    let dead = FakeTmux(info: "%3\t400\t1\t0\t1\t0\n")
    #expect(await typer(dead).type("x", into: target) == .failed("The tmux pane has exited — nothing sent"))
    let missing = FakeTmux(info: "")
    missing.infoStatus = 1
    #expect(await typer(missing).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    let other = FakeTmux(info: "%7\t400\t0\t0\t1\t0\n")             // tmux resolved the target to another pane
    #expect(await typer(other).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    #expect(dead.sendCalls.isEmpty && missing.sendCalls.isEmpty && other.sendCalls.isEmpty)
}

@Test func foreignSocketIsRefused() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake, socketIsUsers: false).type("x", into: target) == .failed("tmux server not found — nothing sent"))
    #expect(fake.calls.isEmpty)
}

@Test func noTmuxOrNoTextIsRefused() async {
    let none = TmuxTyper(run: nil, parentOf: liveParents, isForeground: { _ in true }, socketIsUsers: { _ in true })
    #expect(await none.type("x", into: target) == .failed("tmux not found on the Mac — nothing sent"))
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).type("", into: target) == .failed("Nothing to send"))
    #expect(fake.calls.isEmpty)
}

@Test func failedTypingOrEnterIsReported() async {
    let fake = FakeTmux(info: goodInfo)
    fake.sendStatus = [1]
    #expect(await typer(fake).type("x", into: target) == .failed("tmux could not type — nothing sent"))
    #expect(fake.sendCalls.count == 1)                            // no Enter after a failed send
    let late = FakeTmux(info: goodInfo)
    late.sendStatus = [0, 1]
    #expect(await typer(late).type("x", into: target) == .failed("Typed, but Enter failed — press Enter in the terminal"))
}

@Test func synchronizedPanesAreRefused() async {
    // send-keys would be copied to every synchronized pane in the window, none of them verified
    let fake = FakeTmux(info: "%3\t400\t0\t0\t1\t1\n")
    #expect(await typer(fake).type("x", into: target) == .failed("Panes are synchronized — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func backgroundedSessionIsRefused() async {
    // Ctrl-Z: the pane shows a shell prompt that would run the text as a command
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake, foreground: false).type("x", into: target)
            == .failed("Claude Code is suspended or in the background — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func foregroundIsCheckedOnTheSessionProcess() async {
    // The chain member just below the pane process (Claude Code, 500), or the pane process itself when it is the
    // hook's direct parent
    let asked = FakeTmux(info: goodInfo)
    let seen = Locked<[Int32]>([])
    let t = TmuxTyper(run: asked.runner, parentOf: liveParents, isForeground: { seen.append($0); return true },
                      socketIsUsers: { _ in true }, enterDelay: .zero)
    #expect(await t.verify(target) == nil)
    #expect(await t.verify(PaneTarget(pane: "%3", socket: "/tmp/s", ancestors: [400, 300])) == nil)
    #expect(seen.value == [500, 400])
}

@Test func uncleanTextIsRefused() async {
    // Only VoiceText.forTyping output is typed: a newline would submit early, ESC would drive the TUI
    let fake = FakeTmux(info: goodInfo)
    for text in ["\n", "a\nb", "a\u{1B}[A", "/clear", " x", "a\u{200B}b"] {
        #expect(await typer(fake).type(text, into: target) == .failed("The text is not safe to type — nothing sent"))
    }
    #expect(fake.calls.isEmpty)
}

@Test func timeoutNeverClaimsNothingWasSent() async {
    let fake = FakeTmux(info: goodInfo)
    fake.sendStatus = [TmuxTyper.timedOut]
    #expect(await typer(fake).type("x", into: target) == .failed("tmux timed out — text may have been typed"))
    #expect(fake.sendCalls.count == 1)                            // never retried, no Enter
    let late = FakeTmux(info: goodInfo)
    late.sendStatus = [0, TmuxTyper.timedOut]
    #expect(await typer(late).type("x", into: target) == .failed("Typed, but tmux timed out on Enter — check the terminal"))
    #expect(late.sendCalls.count == 2)
}

@Test func verifyAloneTypesNothing() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).verify(target) == nil)
    #expect(fake.sendCalls.isEmpty)
}

@Test func trailingSemicolonIsEscaped() {
    // tmux strips a trailing ";" from an argument (command separator) and turns a trailing "\;" into ";"
    #expect(TmuxTyper.literalArgument("ok;") == "ok\\;")
    #expect(TmuxTyper.literalArgument("a\\;") == "a\\\\;")
    #expect(TmuxTyper.literalArgument("a;b") == "a;b")
    #expect(TmuxTyper.literalArgument("plain") == "plain")
}

@Test func paneCheckFollowsTheChain() {
    let parents: (Int32) -> Int32? = { [500: 400, 400: 300][$0] }
    #expect(PaneCheck.belongs(panePid: 500, ancestors: [500, 400], parentOf: parents))   // hook's direct parent
    #expect(PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: { _ in nil }))  // 500 is gone
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: { _ in 77 }))   // 500 re-parented
    #expect(!PaneCheck.belongs(panePid: 123, ancestors: [500, 400], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 1, ancestors: [1], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [], parentOf: parents))
}

@Test func socketPathComesFromTheTMUXVariable() {
    #expect(TmuxSocket.path(fromTMUX: "/private/tmp/tmux-501/default,93688,0") == "/private/tmp/tmux-501/default")
    #expect(TmuxSocket.path(fromTMUX: "/tmp/s") == "/tmp/s")
    #expect(TmuxSocket.path(fromTMUX: "") == nil)
    #expect(TmuxSocket.path(fromTMUX: "relative,1,0") == nil)
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func append<E>(_ e: E) where T == [E] { lock.withLock { _value.append(e) } }
}

@Test func processTreeSeesThisProcess() {
    #expect(ProcessTree.parent(of: getpid()) == getppid())
    #expect(ProcessTree.parent(of: 0) == nil)
    #expect(!ProcessTree.isForeground(0))
    let chain = ProcessTree.chain(from: getpid())
    #expect(chain.first == getpid() && chain.count >= 2 && !chain.contains(1) && chain.count <= 8)
    #expect(ProcessTree.chain(from: 10, parentOf: { $0 - 1 }) == [10, 9, 8, 7, 6, 5, 4, 3])   // capped at 8
}

private let tmuxPath = TmuxTyper.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

/// Runs a command synchronously (cleanup in `defer`, where `await` is not allowed)
@discardableResult
private func runNow(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// A private tmux server: its own socket in its own temp directory, no ~/.tmux.conf; never the user's tmux.
/// `close()` (from `defer`, so a failed test cleans up too) kills it and removes the directory.
private struct PrivateTmux {
    let tmux: String
    let dir: URL
    let sock: String
    let run: TmuxTyper.Runner

    init() throws {
        tmux = try #require(tmuxPath)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbt-\(UInt32.random(in: 1...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sock = dir.appendingPathComponent("s").path
        run = TmuxTyper.processRunner(tmux: tmux)
    }

    func close() {
        runNow(tmux, ["-S", sock, "kill-server"])
        try? FileManager.default.removeItem(at: dir)
    }

    /// First pane of a new session running `command`: (pane id, pane pid)
    func start(_ command: String) async throws -> (String, Int32) {
        let (status, out) = await run(["-f", "/dev/null", "-S", sock, "new-session", "-d", "-x", "160", "-y", "20",
                                       "-P", "-F", "#{pane_id} #{pane_pid}", command])
        #expect(status == 0)
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        try #require(parts.count == 2)
        return (String(parts[0]), try #require(Int32(parts[1])))
    }

    func mark(_ pane: String) async {
        _ = await run(["-S", sock, "set-option", "-p", "-t", pane, TmuxTyper.mark, "1"])
    }

    func lines(_ pane: String) async -> [String] {
        try? await Task.sleep(for: .milliseconds(400))
        return await run(["-S", sock, "capture-pane", "-p", "-t", pane]).output.components(separatedBy: "\n")
    }

    var typer: TmuxTyper {
        TmuxTyper(run: run, parentOf: { ProcessTree.parent(of: $0) }, isForeground: { ProcessTree.isForeground($0) },
                  socketIsUsers: { TmuxTyper.socketIsUsers($0) }, enterDelay: .milliseconds(100))
    }
}

@Test(.enabled(if: tmuxPath != nil, "tmux is not installed"))
func realTmuxTypesOnlyIntoAMarkedPane() async throws {
    let t = try PrivateTmux()
    defer { t.close() }
    let (pane, pid) = try await t.start("cat")
    let paneTarget = PaneTarget(pane: pane, socket: t.sock, ancestors: [pid])
    #expect(await t.typer.type("hello", into: paneTarget) == .failed("Open with cb for voice"))
    await t.mark(pane)
    let text = "-x {a} xin chào; ok \\;"                       // leading "-", braces, ";" inside, "\;" at the end
    #expect(await t.typer.type(text, into: paneTarget) == .typed)
    // The tty echoes the typed line, then cat prints it once Enter arrives: exactly two copies, one Enter
    let screen = await t.lines(pane)
    #expect(screen.filter { $0 == text }.count == 2, "\(screen)")
}

@Test(.enabled(if: tmuxPath != nil, "tmux is not installed"))
func realTmuxRefusesSynchronizedPanes() async throws {
    let t = try PrivateTmux()
    defer { t.close() }
    let (pane, pid) = try await t.start("cat")
    let (status, out) = await t.run(["-S", t.sock, "split-window", "-t", pane, "-P", "-F", "#{pane_id}", "cat"])
    #expect(status == 0)
    let sibling = out.trimmingCharacters(in: .whitespacesAndNewlines)
    await t.mark(pane)
    _ = await t.run(["-S", t.sock, "set-option", "-w", "-t", pane, "synchronize-panes", "on"])
    #expect(await t.typer.type("secret", into: PaneTarget(pane: pane, socket: t.sock, ancestors: [pid]))
            == .failed("Panes are synchronized — nothing sent"))
    #expect(await !t.lines(sibling).contains { $0.contains("secret") })
    #expect(await !t.lines(pane).contains { $0.contains("secret") })
}

@Test(.enabled(if: tmuxPath != nil, "tmux is not installed"))
func realTmuxRefusesASuspendedSession() async throws {
    // Stand-ins: sh is the pane process, cat plays Claude Code (the hook's parent)
    let t = try PrivateTmux()
    defer { t.close() }
    let (pane, shPid) = try await t.start("exec /bin/sh")
    _ = await t.run(["-S", t.sock, "send-keys", "-t", pane, "-l", "exec 2>/dev/null; PS1='$ '; cat"])
    _ = await t.run(["-S", t.sock, "send-keys", "-t", pane, "Enter"])
    try await Task.sleep(for: .milliseconds(400))
    let catPid = try #require(Int32(runNow("/usr/bin/pgrep", ["-P", "\(shPid)", "cat"])
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    await t.mark(pane)
    let paneTarget = PaneTarget(pane: pane, socket: t.sock, ancestors: [catPid, shPid])
    #expect(await t.typer.type("hello", into: paneTarget) == .typed)
    _ = await t.run(["-S", t.sock, "send-keys", "-t", pane, "C-z"])
    try await Task.sleep(for: .milliseconds(400))
    #expect(await t.typer.type("echo pwned", into: paneTarget)
            == .failed("Claude Code is suspended or in the background — nothing sent"))
    let screen = await t.lines(pane)
    #expect(screen.filter { $0 == "hello" }.count == 2, "\(screen)")
    #expect(!screen.contains { $0.contains("pwned") }, "\(screen)")
}
