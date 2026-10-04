import ClaudeRelay
import CoreImage
import Foundation

public enum RelayConfig {
    /// The daemon's WebSocket port on its Tailscale address
    public static let port: UInt16 = 47821
    /// ~/.claude-board (CLAUDE_BOARD_HOME overrides it, for trying --pair without touching the real install)
    public static var directory: String {
        ProcessInfo.processInfo.environment["CLAUDE_BOARD_HOME"] ?? NSHomeDirectory() + "/.claude-board"
    }
    public static var secretPath: String { directory + "/relay.secret" }
}

public enum RelaySecretError: Error, Equatable, CustomStringConvertible {
    case missing, notRegularFile, wrongOwner, tooOpen(mode: UInt16), unreadable, malformed

    public var description: String {
        switch self {
        case .missing: "no relay secret"
        case .notRegularFile: "the relay secret is not a regular file (symlink?)"
        case .wrongOwner: "the relay secret belongs to another user"
        case .tooOpen(let m): "the relay secret is readable by others (mode \(String(m, radix: 8)), must be 600)"
        case .unreadable: "the relay secret cannot be read or written"
        case .malformed: "the relay secret is malformed"
        }
    }
}

/// ~/.claude-board/relay.secret: base64url + "\n", mode 0600, owned by the user. Anything else is refused (the
/// relay then stays off) and never silently replaced; `claude-board --pair --new-secret` replaces it on purpose.
public enum RelaySecretFile {
    public static func load(path: String) -> Result<RelaySecret, RelaySecretError> {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(errno == ENOENT ? .missing : .unreadable) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard st.st_uid == getuid() else { return .failure(.wrongOwner) }
        guard st.st_mode & 0o077 == 0 else { return .failure(.tooOpen(mode: UInt16(st.st_mode & 0o777))) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .failure(.unreadable) }
        guard let secret = RelaySecret(base64url: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.malformed)
        }
        return .success(secret)
    }

    /// The existing secret, or a new one when there is none (or `rotate`). Written to a 0600 temp file
    /// (O_EXCL | O_NOFOLLOW) in the 0700 directory, then renamed over the old one.
    public static func loadOrCreate(path: String, rotate: Bool = false) throws -> RelaySecret {
        if !rotate {
            switch load(path: path) {
            case .success(let s): return s
            case .failure(.missing): break
            case .failure(let e): throw e
            }
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let secret = RelaySecret.random()
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RelaySecretError.unreadable }
        let line = Data((secret.base64url + "\n").utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == line.count, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw RelaySecretError.unreadable
        }
        return secret
    }
}

/// The pairing QR code for the terminal (CoreImage: nothing to install).
public enum PairingQR {
    /// Dark modules, top row first, including CoreImage's own margin
    public static func matrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var px = [UInt8](repeating: 255, count: w * h)
        CIContext().render(image, toBitmap: &px, rowBytes: w, bounds: image.extent, format: .L8,
                           colorSpace: CGColorSpaceCreateDeviceGray())
        return (0..<h).map { y in (0..<w).map { x in px[y * w + x] < 128 } }
    }

    /// Two module rows per text line with half blocks, black on white whatever the terminal's colours
    public static func terminal(_ m: [[Bool]], quiet: Int = 2) -> String {
        let size = m.count + 2 * quiet
        func dark(_ y: Int, _ x: Int) -> Bool {
            let (r, c) = (y - quiet, x - quiet)
            return r >= 0 && r < m.count && c >= 0 && c < m.count && m[r][c]
        }
        var lines: [String] = []
        for y in stride(from: 0, to: size, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in 0..<size {
                switch (dark(y, x), dark(y + 1, x)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
