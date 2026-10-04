import Foundation
import Testing
@testable import ClaudeRelay

private let secret = RelaySecret(Data((0..<32).map { UInt8($0) }))!

@Test func tailscaleRanges() {
    for ip in ["100.64.0.1", "100.101.102.103", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::42"] {
        #expect(TailscaleAddress.isTailscale(ip), "\(ip)")
    }
    for ip in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "10.0.0.2", "127.0.0.1", "0.0.0.0", "::1", "::",
               "fd7a:115c:a1e1::1", "fe80::1", "", "localhost", "100.64.0.1.5"] {
        #expect(!TailscaleAddress.isTailscale(ip), "\(ip)")
    }
}

@Test func onlyUtunTailscaleAddressesArePicked() {
    let ifs: [TailscaleAddress.Interface] = [
        .init(name: "en0", address: "192.168.1.20"),
        .init(name: "utun4", address: "fd7a:115c:a1e0::5"),
        .init(name: "utun4", address: "100.101.102.103"),
        .init(name: "lo0", address: "127.0.0.1"),
    ]
    #expect(TailscaleAddress.pick(ifs) == "100.101.102.103")            // IPv4 first
    #expect(TailscaleAddress.pick(Array(ifs.prefix(2))) == "fd7a:115c:a1e0::5")
    #expect(TailscaleAddress.pick([.init(name: "en0", address: "192.168.1.20")]) == nil)
}

@Test func cgnatOnEthernetIsNotTailscale() {
    // A carrier's 100.64/10 address on a real interface is not the tailnet
    #expect(TailscaleAddress.pick([.init(name: "en0", address: "100.70.1.2")]) == nil)
    #expect(TailscaleAddress.pick([.init(name: "pdp_ip0", address: "100.70.1.2")]) == nil)
}

@Test func interfaceScanFindsLoopback() {
    // The scan itself works on any Mac (no Tailscale needed): lo0 always has 127.0.0.1
    #expect(TailscaleAddress.interfaces().contains { $0.name == "lo0" && $0.address == "127.0.0.1" })
}

@Test func pairingURLVector() {
    let p = RelayPairing(host: "100.101.102.103", port: 47821, secret: secret)
    #expect(p.url == "claudeboard://relay?v=1&h=100.101.102.103&p=47821&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    #expect(RelayPairing.parse(p.url) == p)
    #expect(p.webSocketURL.absoluteString == "ws://100.101.102.103:47821/relay")
    let v6 = RelayPairing(host: "fd7a:115c:a1e0::5", port: 47821, secret: secret)
    #expect(RelayPairing.parse(v6.url) == v6)
    #expect(v6.webSocketURL.absoluteString == "ws://[fd7a:115c:a1e0::5]:47821/relay")
}

@Test func pairingRefusesAnythingElse() {
    let s = "s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    for bad in [
        "claudeboard://relay?v=1&h=192.168.1.20&p=47821&\(s)",           // not a Tailscale address
        "claudeboard://relay?v=1&h=evil.example.com&p=47821&\(s)",
        "claudeboard://relay?v=2&h=100.101.102.103&p=47821&\(s)",
        "claudeboard://relay?v=1&h=100.101.102.103&p=0&\(s)",
        "claudeboard://relay?v=1&h=100.101.102.103&p=70000&\(s)",
        "claudeboard://relay?v=1&h=100.101.102.103&p=47821",
        "claudeboard://relay?v=1&h=100.101.102.103&h=100.64.0.1&p=47821&\(s)",   // duplicate host
        "https://relay?v=1&h=100.101.102.103&p=47821&\(s)",
        "claudeboard://other?v=1&h=100.101.102.103&p=47821&\(s)",
        "not a url",
    ] {
        #expect(RelayPairing.parse(bad) == nil, "\(bad)")
    }
}
