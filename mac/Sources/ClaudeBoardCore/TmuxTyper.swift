import Foundation

/// The tmux pane a session runs in, as its hooks reported it.
public struct PaneTarget: Equatable, Sendable {
    /// "%3" ($TMUX_PANE)
    public let pane: String
    /// tmux server socket ($TMUX up to its first comma)
    public let socket: String
    /// The hook's parent process and that process's parents, nearest first (HookEnvelope)
    public let ancestors: [Int32]

    public init(pane: String, socket: String, ancestors: [Int32]) {
        self.pane = pane
        self.socket = socket
        self.ancestors = ancestors
    }
}

public enum TypeResult: Equatable, Sendable {
    case typed
    /// Nothing was typed (except the documented Enter failure); the text is shown on the board
    case failed(String)
}

public protocol PaneTyping: Sendable {
    /// nil when `target` is a cb pane that still runs this session; else why not (shown on the board)
    func verify(_ target: PaneTarget) async -> String?
    /// Verifies again, then types `text` literally and presses Enter once
    func type(_ text: String, into target: PaneTarget) async -> TypeResult
}

public enum TmuxSocket {
    /// "$TMUX" is "<socket path>,<server pid>,<session index>"
    public static func path(fromTMUX value: String) -> String? {
        guard let first = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.hasPrefix("/") else { return nil }
        return String(first)
    }
}

public enum PaneCheck {
    /// The pane's root process is in the session's recorded chain, and the chain member just below it (if any)
    /// is still its child: Claude Code (or cb exec'd into it) is still running in that pane.
    public static func belongs(panePid: Int32, ancestors: [Int32], parentOf: (Int32) -> Int32?) -> Bool {
        sessionProcess(panePid: panePid, ancestors: ancestors, parentOf: parentOf) != nil
    }

    /// The session's process in the pane (the chain member just below the pane process, or the pane process
    /// itself when it is the hook's direct parent), nil when the pane does not belong to the session
    static func sessionProcess(panePid: Int32, ancestors: [Int32], parentOf: (Int32) -> Int32?) -> Int32? {
        guard panePid > 1, let k = ancestors.firstIndex(of: panePid) else { return nil }
        if k == 0 { return panePid }
        return parentOf(ancestors[k - 1]) == panePid ? ancestors[k - 1] : nil
    }
}

public enum ProcessTree {
    /// Parent pid of a live process, nil when it does not exist
    public static func parent(of pid: Int32) -> Int32? { info(pid)?.kp_eproc.e_ppid }

    /// The process is in its terminal's foreground process group: not stopped by Ctrl-Z nor sent to the
    /// background, so keys typed into the terminal reach it rather than a shell prompt
    public static func isForeground(_ pid: Int32) -> Bool {
        guard let p = info(pid) else { return false }
        return p.kp_eproc.e_tpgid > 0 && p.kp_eproc.e_pgid == p.kp_eproc.e_tpgid
    }

    private static func info(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// pid, its parent, its grandparent… (at most `max`, stopping before launchd)
    public static func chain(from pid: Int32, max: Int = 8,
                             parentOf: (Int32) -> Int32? = ProcessTree.parent(of:)) -> [Int32] {
        var out: [Int32] = []
        var p = pid
        while p > 1 && out.count < max {
            out.append(p)
            guard let next = parentOf(p) else { break }
            p = next
        }
        return out
    }
}

/// Types voice text into a verified cb pane with `send-keys -l`, then one Enter.
public struct TmuxTyper: PaneTyping {
    public typealias Runner = @Sendable (_ arguments: [String]) async -> (status: Int32, output: String)

    /// Pane option set by mac/cb
    public static let mark = "@claude_board"
    public static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let infoFormat = "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_in_mode}\t#{\(mark)}\t#{pane_synchronized}"
    /// Runner status when tmux had to be killed (5 s timeout, or any signal): it may have acted already
    public static let timedOut: Int32 = -2

    private let run: Runner?
    private let parentOf: @Sendable (Int32) -> Int32?
    private let isForeground: @Sendable (Int32) -> Bool
    private let socketIsUsers: @Sendable (String) -> Bool
    private let enterDelay: Duration

    public init(run: Runner?, parentOf: @escaping @Sendable (Int32) -> Int32?,
                isForeground: @escaping @Sendable (Int32) -> Bool,
                socketIsUsers: @escaping @Sendable (String) -> Bool, enterDelay: Duration = .milliseconds(200)) {
        self.run = run
        self.parentOf = parentOf
        self.isForeground = isForeground
        self.socketIsUsers = socketIsUsers
        self.enterDelay = enterDelay
    }

    /// The real tmux (Homebrew or system), the real process table and socket ownership check
    public static func system() -> TmuxTyper {
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return TmuxTyper(run: path.map { processRunner(tmux: $0) }, parentOf: { ProcessTree.parent(of: $0) },
                         isForeground: { ProcessTree.isForeground($0) }, socketIsUsers: { socketIsUsers($0) })
    }

    public func verify(_ t: PaneTarget) async -> String? {
        guard let run else { return "tmux not found on the Mac — nothing sent" }
        guard socketIsUsers(t.socket) else { return "tmux server not found — nothing sent" }
        let (status, out) = await run(["-S", t.socket, "display-message", "-p", "-t", t.pane, Self.infoFormat])
        let f = out.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard status == 0, f.count == 6, f[0] == t.pane, let panePid = Int32(f[1]) else {
            return "The tmux pane is gone — nothing sent"
        }
        guard f[2] == "0" else { return "The tmux pane has exited — nothing sent" }
        guard f[4] == "1" else { return "Open with cb for voice" }
        guard let session = PaneCheck.sessionProcess(panePid: panePid, ancestors: t.ancestors, parentOf: parentOf) else {
            return "The pane runs another program now — nothing sent"
        }
        // Ctrl-Z leaves a shell prompt in the pane that would run the text as a command
        guard isForeground(session) else { return "Claude Code is suspended or in the background — nothing sent" }
        // send-keys is copied to every synchronized pane in the window, and those are not verified
        guard f[5] == "0" else { return "Panes are synchronized — nothing sent" }
        guard f[3] == "0" else { return "The terminal is in copy mode — nothing sent" }
        return nil
    }

    public func type(_ text: String, into t: PaneTarget) async -> TypeResult {
        guard !text.isEmpty else { return .failed("Nothing to send") }
        // Only what the board showed: no newline that submits early, no ESC that drives the TUI, no mode prefix
        guard text.unicodeScalars.elementsEqual(VoiceText.forTyping(text).unicodeScalars) else {
            return .failed("The text is not safe to type — nothing sent")
        }
        if let problem = await verify(t) { return .failed(problem) }
        guard let run else { return .failed("tmux not found on the Mac — nothing sent") }
        let (typed, _) = await run(["-S", t.socket, "send-keys", "-t", t.pane, "-l", "--", Self.literalArgument(text)])
        // Never retried: a killed tmux may have typed already
        if typed == Self.timedOut { return .failed("tmux timed out — text may have been typed") }
        guard typed == 0 else { return .failed("tmux could not type — nothing sent") }
        // Let Claude Code take the text as typing, not as part of a paste that would swallow the Enter
        try? await Task.sleep(for: enterDelay)
        let (entered, _) = await run(["-S", t.socket, "send-keys", "-t", t.pane, "Enter"])
        if entered == Self.timedOut { return .failed("Typed, but tmux timed out on Enter — check the terminal") }
        return entered == 0 ? .typed : .failed("Typed, but Enter failed — press Enter in the terminal")
    }

    /// tmux treats an argument ending in ";" as a command separator (and "\;" as a literal ";"): end such text
    /// with "\;" so the pane receives exactly `text`.
    static func literalArgument(_ text: String) -> String {
        text.hasSuffix(";") ? String(text.dropLast()) + "\\;" : text
    }

    /// Runs tmux without a shell (arguments are never interpreted); kills it after 5 s (status `timedOut`)
    public static func processRunner(tmux: String) -> Runner {
        { args in
            await withCheckedContinuation { (c: CheckedContinuation<(status: Int32, output: String), Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tmux)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { proc in
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let status = proc.terminationReason == .uncaughtSignal ? timedOut : proc.terminationStatus
                    c.resume(returning: (status, String(decoding: data, as: UTF8.self)))
                }
                do {
                    try p.run()
                } catch {
                    c.resume(returning: (-1, ""))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            }
        }
    }

    /// A Unix socket owned by this user (never type into another user's tmux server)
    public static func socketIsUsers(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
    }
}
