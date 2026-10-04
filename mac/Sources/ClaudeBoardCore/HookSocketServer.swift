import Foundation

/// The daemon's Unix socket (BSD sockets, not Network.framework: an NWListener never surfaces a connection whose
/// client wrote its line and closed before the accept, which is what a fire-and-forget hook does).
/// Every complete line ("…\n") is handed to `onLine` exactly once, in order, before the end of the stream is acted
/// on; a partial line at the end is dropped. The hook sends one line per connection.
public final class HookSocketServer: @unchecked Sendable {
    public typealias Acceptor = @Sendable (_ listener: Int32) -> Int32

    public let path: String
    private let maxLineBytes: Int
    private let idleTimeout: TimeInterval
    private let acceptBackoff: TimeInterval
    private let acceptor: Acceptor
    private let onLine: @Sendable (Data, any HookConnection) -> Void
    private let queue = DispatchQueue(label: "claude-board.accept")
    /// The listening descriptor (-1 before start)
    private(set) var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var suspended = false
    private var stopped = false

    /// `onLine` runs on the connection's queue: hand the work off, never block it.
    /// A connection that has not sent a complete line within `idleTimeout` is closed; one whose line was delivered
    /// lives until that line is answered. When accept runs out of descriptors, accepting pauses for `acceptBackoff`.
    public init(path: String, maxLineBytes: Int = 4 * 1024 * 1024, idleTimeout: TimeInterval = 10,
                acceptBackoff: TimeInterval = 0.1, acceptor: @escaping Acceptor = { accept($0, nil, nil) },
                onLine: @escaping @Sendable (Data, any HookConnection) -> Void) {
        self.path = path
        self.maxLineBytes = maxLineBytes
        self.idleTimeout = idleTimeout
        self.acceptBackoff = acceptBackoff
        self.acceptor = acceptor
        self.onLine = onLine
    }

    /// Replaces any socket file at `path`, owner-only (0600), and starts accepting
    public func start() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.lastError() }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard Self.setCloseOnExec(fd), bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0,
              Self.setNonBlocking(fd) else {
            let error = Self.lastError()
            close(fd)
            throw error
        }
        listenFD = fd
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptAll() }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    /// Stops accepting (connections already accepted carry on) and removes the socket file
    public func stop() {
        queue.sync {
            stopped = true
            source?.cancel()
            if suspended { source?.resume() }   // a suspended source never runs its cancel handler
            suspended = false
            source = nil
        }
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let c = acceptor(listenFD)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                if errno == EMFILE || errno == ENFILE { pauseAccepting() }
                return   // EAGAIN: none left
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard Self.setCloseOnExec(c), Self.setNonBlocking(c) else { close(c); continue }
            SocketHookConnection(fd: c, maxLineBytes: maxLineBytes, idleTimeout: idleTimeout, onLine: onLine).start()
        }
    }

    /// Out of descriptors: the pending connection keeps the listener readable, so stop listening for a moment
    /// instead of spinning on accept
    private func pauseAccepting() {
        guard let source, !suspended else { return }
        suspended = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + acceptBackoff) { [self] in
            guard suspended, !stopped else { return }
            suspended = false
            source.resume()
        }
    }

    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Never inherited by a process started meanwhile on another thread (tmux, the speech engine…)
    static func setCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func lastError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// One accepted connection. All state lives on `queue`. The descriptor is closed once every delivered line has been
/// answered (reply or close), at once when the client ends the stream before sending a complete line, or when no
/// complete line arrived within the idle timeout.
final class SocketHookConnection: @unchecked Sendable {
    let fd: Int32
    private let maxLineBytes: Int
    private let idleTimeout: TimeInterval
    private let onLine: @Sendable (Data, any HookConnection) -> Void
    private let queue = DispatchQueue(label: "claude-board.hook-connection")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    /// Bytes at the start of `buffer` already known to hold no newline
    private var scanned = 0
    /// Lines handed out, and those not yet answered
    private var delivered = 0
    private var open = 0
    private var peerGone = false
    private var closed = false
    private var sourceDone = false
    private var goneHandlers: [@Sendable () -> Void] = []
    /// A reply waits at most this long for the client to take it
    static let replyTimeout: TimeInterval = 5

    init(fd: Int32, maxLineBytes: Int, idleTimeout: TimeInterval,
         onLine: @escaping @Sendable (Data, any HookConnection) -> Void) {
        self.fd = fd
        self.maxLineBytes = maxLineBytes
        self.idleTimeout = idleTimeout
        self.onLine = onLine
    }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The connection stays alive (retained by its source) until the source is cancelled
        s.setEventHandler { self.readAvailable() }
        s.setCancelHandler {
            self.sourceDone = true
            self.source = nil
            if self.closed { Darwin.close(self.fd) }
        }
        source = s
        s.resume()
        // A client that never finishes its line must not hold a descriptor forever
        queue.asyncAfter(deadline: .now() + idleTimeout) {
            if self.delivered == 0 { self.closeNow() }
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var ended = false
        while !closed {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                deliverLines()           // also enforces the size limit, chunk by chunk
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            ended = true      // EOF, or an error such as ECONNRESET: the client is gone
            break
        }
        if ended && !closed {
            peerGone = true
            source?.cancel()               // nothing more to read; the descriptor stays open for replies
            fireGone()
            if open == 0 { closeNow() }    // a partial line is dropped
        }
    }

    /// Hands over every complete line in the buffer, in order. An oversized line (complete or not) closes the
    /// connection without a reply.
    private func deliverLines() {
        while !closed {
            guard let nl = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0a) else {
                scanned = buffer.count
                if buffer.count > maxLineBytes { closeNow() }
                return
            }
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            scanned = 0
            guard line.count <= maxLineBytes else { closeNow(); return }
            delivered += 1
            open += 1
            onLine(line, LineHandle(self))
        }
    }

    private func fireGone() {
        let handlers = goneHandlers
        goneHandlers = []
        handlers.forEach { $0() }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        if sourceDone { Darwin.close(fd) } else { source?.cancel() }   // the cancel handler closes it
        peerGone = true
        fireGone()
    }

    // MARK: - HookConnection, per delivered line

    fileprivate func onPeerGone(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            if self.peerGone { handler() } else { self.goneHandlers.append(handler) }
        }
    }

    fileprivate func reply(_ reply: BridgeReply) {
        var line = (try? JSONEncoder().encode(reply)) ?? Data("{}".utf8)
        line.append(0x0a)
        let data = line
        queue.async {
            if !self.closed { self.write(data) }
            self.finishLine()
        }
    }

    fileprivate func close() {
        queue.async { self.finishLine() }
    }

    private func finishLine() {
        open -= 1
        if open <= 0 { closeNow() }
    }

    private func write(_ data: Data) {
        let deadline = Date().addingTimeInterval(Self.replyTimeout)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return }
            let ms = Int32(deadline.timeIntervalSinceNow * 1000)
            guard ms > 0 else { return }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&p, 1, ms) < 0 && errno != EINTR { return }
        }
    }
}

/// The HookConnection for one line: answered once (a reply or a close), later calls are ignored
final class LineHandle: HookConnection, @unchecked Sendable {
    let connection: SocketHookConnection
    private let lock = NSLock()
    private var answered = false

    init(_ connection: SocketHookConnection) { self.connection = connection }

    private func answerOnce() -> Bool {
        lock.withLock {
            defer { answered = true }
            return !answered
        }
    }

    func onPeerGone(_ handler: @escaping @Sendable () -> Void) { connection.onPeerGone(handler) }
    func reply(_ reply: BridgeReply) { if answerOnce() { connection.reply(reply) } }
    func close() { if answerOnce() { connection.close() } }
}
