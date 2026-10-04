import ClaudeRelay
import CoreImage
import Foundation
import Testing
@testable import ClaudeBoardCore

private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "relay-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func mode(_ path: String) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
}

@Test func secretIsCreatedOwnerOnlyAndReloaded() throws {
    let path = tempDir() + "/sub/relay.secret"
    let s = try RelaySecretFile.loadOrCreate(path: path)
    #expect(mode(path) == 0o600)
    #expect(mode((path as NSString).deletingLastPathComponent) == 0o700)
    #expect(try RelaySecretFile.load(path: path).get() == s)
    #expect(try RelaySecretFile.loadOrCreate(path: path) == s)            // kept
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text == s.base64url + "\n")
}

@Test func rotateReplacesTheSecret() throws {
    let path = tempDir() + "/relay.secret"
    let a = try RelaySecretFile.loadOrCreate(path: path)
    let b = try RelaySecretFile.loadOrCreate(path: path, rotate: true)
    #expect(a != b)
    #expect(try RelaySecretFile.load(path: path).get() == b)
    #expect(mode(path) == 0o600)
}

@Test func unsafeSecretFilesAreRefused() throws {
    let dir = tempDir()
    let open = dir + "/open"
    _ = try RelaySecretFile.loadOrCreate(path: open)
    chmod(open, 0o644)
    #expect(RelaySecretFile.load(path: open) == .failure(.tooOpen(mode: 0o644)))
    #expect(throws: RelaySecretError.tooOpen(mode: 0o644)) { try RelaySecretFile.loadOrCreate(path: open) }  // never replaced silently

    let real = dir + "/real"
    _ = try RelaySecretFile.loadOrCreate(path: real)
    let link = dir + "/link"
    symlink(real, link)
    #expect(RelaySecretFile.load(path: link) == .failure(.notRegularFile))

    let junk = dir + "/junk"
    FileManager.default.createFile(atPath: junk, contents: Data("not a secret\n".utf8), attributes: [.posixPermissions: 0o600])
    #expect(RelaySecretFile.load(path: junk) == .failure(.malformed))
    #expect(RelaySecretFile.load(path: dir + "/missing") == .failure(.missing))
}

@Test func existingDirectoryIsTightenedTo0700() throws {
    let dir = tempDir() + "/home"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])   // as install.sh's mkdir -p "$BIN" did
    _ = try RelaySecretFile.loadOrCreate(path: dir + "/relay.secret")
    #expect(mode(dir) == 0o700)
}

@Test func symlinkedDirectoryIsRefused() throws {
    let base = tempDir()
    let real = base + "/real"
    try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
    symlink(real, base + "/home")
    #expect(throws: RelaySecretError.unsafeDirectory) { try RelaySecretFile.loadOrCreate(path: base + "/home/relay.secret") }
    #expect(!FileManager.default.fileExists(atPath: real + "/relay.secret"))
}

@Test func nonRegularSecretPathsAreRefused() throws {
    let dir = tempDir()
    let fifo = dir + "/fifo"
    mkfifo(fifo, 0o600)
    #expect(RelaySecretFile.load(path: fifo) == .failure(.notRegularFile))   // and does not block
    let sub = dir + "/sub"
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(RelaySecretFile.load(path: sub) == .failure(.notRegularFile))
}

/// Renders a module matrix as a grey bitmap (quiet zone 4, 8 px per module) and decodes it with CoreImage
private func decode(_ m: [[Bool]]) -> String? {
    let scale = 8, quiet = 4, n = (m.count + 2 * quiet) * scale
    var px = [UInt8](repeating: 255, count: n * n)
    for (y, row) in m.enumerated() {
        for (x, dark) in row.enumerated() where dark {
            for dy in 0..<scale { for dx in 0..<scale { px[((y + quiet) * scale + dy) * n + (x + quiet) * scale + dx] = 0 } }
        }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
    return (detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString
}

@Test func pairingQRDecodesToTheURL() throws {
    let url = RelayPairing(host: "100.101.102.103", port: RelayConfig.port, secret: RelaySecret.random()).url
    let m = try #require(PairingQR.matrix(url))
    #expect(m.count == m.first?.count)
    #expect(decode(m) == url)
}

@Test func pairingQRIsUprightWithoutMargin() throws {
    // Finder patterns top-left, top-right and bottom-left (not bottom-right: that would be a mirrored code), and the
    // matrix starts at the symbol itself (the quiet zone is added by terminal())
    let m = try #require(PairingQR.matrix("claudeboard://relay?v=1&h=100.101.102.103&p=47821"))
    let n = m.count
    let finderRow = { (y: Int, x: Int) in (x..<x + 7).allSatisfy { m[y][$0] } }
    #expect(finderRow(0, 0) && finderRow(6, 0))
    #expect(finderRow(0, n - 7) && finderRow(6, n - 7))
    #expect(finderRow(n - 7, 0) && finderRow(n - 1, 0))
    #expect(!(finderRow(n - 7, n - 7) && finderRow(n - 1, n - 7)))
    #expect((8..<n - 8).allSatisfy { m[6][$0] == ($0 % 2 == 0) })     // horizontal timing pattern on row 6
}

@Test func terminalQRHasAFourModuleQuietZone() throws {
    let m = try #require(PairingQR.matrix("claudeboard://relay?v=1"))
    let lines = PairingQR.terminal(m).split(separator: "\n").map { String($0.dropFirst(8).dropLast(4)) }
    #expect(lines.count == (m.count + 8 + 1) / 2)
    #expect(lines.prefix(2).allSatisfy { $0.allSatisfy { $0 == " " } })
    #expect(lines.allSatisfy { $0.count == m.count + 8 && $0.prefix(4).allSatisfy { $0 == " " } && $0.suffix(4).allSatisfy { $0 == " " } })
}

@Test func terminalQRUsesHalfBlocksOnWhite() throws {
    let m = try #require(PairingQR.matrix("claudeboard://relay?v=1"))
    let lines = PairingQR.terminal(m, quiet: 2).split(separator: "\n")
    #expect(lines.count == (m.count + 4 + 1) / 2)
    #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
}
