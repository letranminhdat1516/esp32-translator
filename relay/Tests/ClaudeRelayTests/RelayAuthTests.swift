import Foundation
import Testing
@testable import ClaudeRelay

private let secret = RelaySecret(Data((0..<32).map { UInt8($0) }))!
private let nonceS = Data(repeating: 0x11, count: 32)
private let nonceC = Data(repeating: 0x22, count: 32)

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

@Test func proofVectors() {
    #expect(secret.base64url == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    #expect(RelaySecret(base64url: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8") == secret)
    #expect(hex(RelayAuth.clientProof(secret, server: nonceS, client: nonceC))
            == "332a196afabe6ab2b492ba08f835602b52e2c327016a00b083aff37647bfc636")
    #expect(hex(RelayAuth.serverProof(secret, server: nonceS, client: nonceC))
            == "3e25f1bef14172ec012a9220275b5b255f5e66a4f5ed02b4e3cf7431f745529f")
}

@Test func secretsRejectBadEncodings() {
    #expect(RelaySecret(Data(count: 31)) == nil)
    #expect(RelaySecret(base64url: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=") == nil)   // padding
    #expect(RelaySecret(base64url: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh") == nil)     // 31 bytes
    #expect(RelaySecret(base64url: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdH+8") == nil)    // '+' is not base64url
    #expect(RelaySecret.random() != RelaySecret.random())
}

@Test func handshakeAuthenticatesBothSides() {
    var server = ServerHandshake(secret: secret, nonce: nonceS)
    var client = ClientHandshake(secret: secret, nonce: nonceC)
    guard case .send(let auth) = client.receive(server.challenge) else { Issue.record("no auth"); return }
    #expect(auth == .auth(nonce: nonceC, proof: RelayAuth.clientProof(secret, server: nonceS, client: nonceC)))
    guard case .accepted(let welcome) = server.receive(auth) else { Issue.record("not accepted"); return }
    #expect(client.receive(welcome) == .authenticated)
}

@Test func wrongSecretIsRejected() {
    var server = ServerHandshake(secret: secret, nonce: nonceS)
    var client = ClientHandshake(secret: RelaySecret.random(), nonce: nonceC)
    guard case .send(let auth) = client.receive(server.challenge) else { Issue.record("no auth"); return }
    #expect(server.receive(auth) == .rejected)
}

@Test func replayedAuthIsRejected() {
    // An eavesdropper replays a recorded auth against a new connection: the new challenge's nonce differs
    var first = ServerHandshake(secret: secret, nonce: nonceS)
    var client = ClientHandshake(secret: secret, nonce: nonceC)
    guard case .send(let recorded) = client.receive(first.challenge) else { Issue.record("no auth"); return }
    #expect(first.receive(recorded) != .rejected)
    var second = ServerHandshake(secret: secret)          // fresh random nonce
    #expect(second.receive(recorded) == .rejected)
}

@Test func onlyOneAuthPerConnection() {
    var server = ServerHandshake(secret: secret, nonce: nonceS)
    var client = ClientHandshake(secret: secret, nonce: nonceC)
    guard case .send(let auth) = client.receive(server.challenge) else { Issue.record("no auth"); return }
    _ = server.receive(auth)
    #expect(server.receive(auth) == .rejected)
}

@Test func fakeMacIsRejected() {
    var client = ClientHandshake(secret: secret, nonce: nonceC)
    let impostor = ServerHandshake(secret: RelaySecret.random(), nonce: nonceS)
    _ = client.receive(impostor.challenge)
    // The impostor cannot compute the server proof; replaying the client's own proof does not work either
    #expect(client.receive(.welcome(RelayAuth.clientProof(secret, server: nonceS, client: nonceC))) == .rejected)
}

@Test func clientRefusesAnythingButTheExpectedStep() {
    var c1 = ClientHandshake(secret: secret, nonce: nonceC)
    #expect(c1.receive(.welcome(Data(count: 32))) == .rejected)                    // welcome before challenge
    var c2 = ClientHandshake(secret: secret, nonce: nonceC)
    #expect(c2.receive(.challenge(Data([2]) + nonceS)) == .rejected)                // unknown version
    var c3 = ClientHandshake(secret: secret, nonce: nonceC)
    #expect(c3.receive(.challenge(Data([1]) + nonceC)) == .rejected)                // reflected nonce
    var c4 = ClientHandshake(secret: secret, nonce: nonceC)
    #expect(c4.receive(.toBoard(Data([2, 1, 0, 0, 0]))) == .rejected)               // data before auth
}

@Test func serverRefusesAReflectedNonce() {
    var server = ServerHandshake(secret: secret, nonce: nonceS)
    let proof = RelayAuth.clientProof(secret, server: nonceS, client: nonceS)
    #expect(server.receive(.auth(nonce: nonceS, proof: proof)) == .rejected)
}
