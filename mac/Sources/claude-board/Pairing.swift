import ClaudeBoardCore
import ClaudeRelay
import Foundation

/// claude-board --pair [--new-secret]: creates the relay secret when missing (or a new one) and prints the QR code
/// the iPhone app scans once. Exit 0 printed, 2 no Tailscale address (the secret exists anyway), 1 error.
/// The secret is never printed as text: it is only inside the QR code.
func runPair(newSecret: Bool) -> Int32 {
    let secret: RelaySecret
    do {
        secret = try RelaySecretFile.loadOrCreate(path: RelayConfig.secretPath, rotate: newSecret)
    } catch {
        print("Relay secret: \(error). Fix or remove \(RelayConfig.secretPath), or run: claude-board --pair --new-secret")
        return 1
    }
    guard let host = TailscaleAddress.pick(TailscaleAddress.interfaces()) else {
        print("""
        No Tailscale address on this Mac, so the iPhone relay is off (the daemon never listens anywhere else).
        Install Tailscale on this Mac and on the iPhone, sign both in to the same tailnet, then run:
          ~/.claude-board/bin/claude-board --pair
        """)
        return 2
    }
    let pairing = RelayPairing(host: host, port: RelayConfig.port, secret: secret)
    guard let matrix = PairingQR.matrix(pairing.url) else {
        print("Could not render the QR code")
        return 1
    }
    print(PairingQR.terminal(matrix))
    print("Scan it in Live Translator on the iPhone: Claude relay → Pair with Mac.")
    print("Relay: \(host) port \(RelayConfig.port), Tailscale only. The code contains the pairing secret: do not share it.")
    if newSecret {
        print("New secret: restart the daemon (launchctl kickstart -k gui/$(id -u)/dev.cicca.claude-board) and scan again.")
    }
    return 0
}
