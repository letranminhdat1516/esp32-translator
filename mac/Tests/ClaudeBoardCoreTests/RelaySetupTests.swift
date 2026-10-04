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

@Test func terminalQRUsesHalfBlocksOnWhite() throws {
    let m = try #require(PairingQR.matrix("claudeboard://relay?v=1"))
    let lines = PairingQR.terminal(m, quiet: 2).split(separator: "\n")
    #expect(lines.count == (m.count + 4 + 1) / 2)
    #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
}
