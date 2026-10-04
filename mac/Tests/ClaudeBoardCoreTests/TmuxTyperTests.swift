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
                   socketIsUsers: Bool = true) -> TmuxTyper {
    TmuxTyper(run: fake.runner, parentOf: parentOf, socketIsUsers: { _ in socketIsUsers }, enterDelay: .zero)
}

private let goodInfo = "%3\t400\t0\t0\t1\n"

@Test func verifiedPaneGetsTheTextThenOneEnter() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).type("chạy các bài kiểm tra", into: target) == .typed)
    #expect(fake.calls.first == ["-S", "/tmp/s", "display-message", "-p", "-t", "%3",
                                 "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_in_mode}\t#{@claude_board}"])
    #expect(fake.sendCalls == [["-S", "/tmp/s", "send-keys", "-t", "%3", "-l", "--", "chạy các bài kiểm tra"],
                               ["-S", "/tmp/s", "send-keys", "-t", "%3", "Enter"]])
}

@Test func unmarkedPaneIsRefused() async {
    let fake = FakeTmux(info: "%3\t400\t0\t0\t\n")
    #expect(await typer(fake).type("x", into: target) == .failed("Open with cb for voice"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func paneOfAnotherProcessIsRefused() async {
    let fake = FakeTmux(info: "%3\t999\t0\t0\t1\n")
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
    let fake = FakeTmux(info: "%3\t400\t0\t1\t1\n")
    #expect(await typer(fake).type("x", into: target) == .failed("The terminal is in copy mode — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func deadOrMissingPaneIsRefused() async {
    let dead = FakeTmux(info: "%3\t400\t1\t0\t1\n")
    #expect(await typer(dead).type("x", into: target) == .failed("The tmux pane has exited — nothing sent"))
    let missing = FakeTmux(info: "")
    missing.infoStatus = 1
    #expect(await typer(missing).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    let other = FakeTmux(info: "%7\t400\t0\t0\t1\n")             // tmux resolved the target to another pane
    #expect(await typer(other).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    #expect(dead.sendCalls.isEmpty && missing.sendCalls.isEmpty && other.sendCalls.isEmpty)
}

@Test func foreignSocketIsRefused() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake, socketIsUsers: false).type("x", into: target) == .failed("tmux server not found — nothing sent"))
    #expect(fake.calls.isEmpty)
}

@Test func noTmuxOrNoTextIsRefused() async {
    let none = TmuxTyper(run: nil, parentOf: liveParents, socketIsUsers: { _ in true })
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

@Test func processTreeSeesThisProcess() {
    #expect(ProcessTree.parent(of: getpid()) == getppid())
    #expect(ProcessTree.parent(of: 0) == nil)
    let chain = ProcessTree.chain(from: getpid())
    #expect(chain.first == getpid() && chain.count >= 2 && !chain.contains(1) && chain.count <= 8)
    #expect(ProcessTree.chain(from: 10, parentOf: { $0 - 1 }) == [10, 9, 8, 7, 6, 5, 4, 3])   // capped at 8
}

private let tmuxPath = TmuxTyper.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

@Test(.enabled(if: tmuxPath != nil, "tmux is not installed"))
func realTmuxTypesOnlyIntoAMarkedPane() async throws {
    let run = TmuxTyper.processRunner(tmux: try #require(tmuxPath))
    // A private server in a private directory: never the user's tmux; kill-server leaves the socket file behind
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbt-\(UInt32.random(in: 1...UInt32.max))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("s").path
    let (status, out) = await run(["-S", sock, "new-session", "-d", "-x", "160", "-y", "20",
                                   "-P", "-F", "#{pane_id} #{pane_pid}", "cat"])
    #expect(status == 0)
    let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    let pane = String(parts[0])
    let pid = try #require(Int32(parts[1]))
    let typer = TmuxTyper(run: run, parentOf: { ProcessTree.parent(of: $0) },
                          socketIsUsers: { TmuxTyper.socketIsUsers($0) }, enterDelay: .milliseconds(100))
    let paneTarget = PaneTarget(pane: pane, socket: sock, ancestors: [pid])
    #expect(await typer.type("hello", into: paneTarget) == .failed("Open with cb for voice"))
    _ = await run(["-S", sock, "set-option", "-p", "-t", pane, TmuxTyper.mark, "1"])
    let text = "-x {a} xin chào; ok \\;"                       // leading "-", braces, ";" inside, "\;" at the end
    #expect(await typer.type(text, into: paneTarget) == .typed)
    try await Task.sleep(for: .milliseconds(400))
    let (_, screen) = await run(["-S", sock, "capture-pane", "-p", "-t", pane])
    // The tty echoes the typed line, then cat prints it once Enter arrives: exactly two copies, one Enter
    #expect(screen.components(separatedBy: "\n").filter { $0 == text }.count == 2, "\(screen)")
    _ = await run(["-S", sock, "kill-server"])
}
