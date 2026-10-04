import CryptoKit
import Foundation

/// The pairing secret: 32 random bytes, base64url without padding in the QR code and in ~/.claude-board/relay.secret.
public struct RelaySecret: Equatable, Sendable {
    public let bytes: Data

    public init?(_ bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = Data(bytes)
    }

    public init?(base64url s: String) {
        guard s.count == 43, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        let standard = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let d = Data(base64Encoded: standard) else { return nil }
        self.init(d)
    }

    public var base64url: String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func random() -> RelaySecret { RelaySecret(RelayAuth.randomBytes(32))! }
}

/// Mutual HMAC-SHA256 challenge-response. Fresh nonces on both sides per connection (replay), distinct labels
/// per direction (reflection), constant-time checks. The secret itself never goes over the wire.
public enum RelayAuth {
    public static let nonceSize = 32
    static let clientLabel = Data("cbrelay1 client".utf8)
    static let serverLabel = Data("cbrelay1 server".utf8)

    /// SystemRandomNumberGenerator is cryptographically secure on Apple platforms
    public static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    public static func clientProof(_ secret: RelaySecret, server: Data, client: Data) -> Data {
        proof(secret, clientLabel, server, client)
    }

    public static func serverProof(_ secret: RelaySecret, server: Data, client: Data) -> Data {
        proof(secret, serverLabel, server, client)
    }

    static func valid(_ proof: Data, _ secret: RelaySecret, _ label: Data, _ server: Data, _ client: Data) -> Bool {
        proof.count == 32 && HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: label + server + client,
                                                                     using: SymmetricKey(data: secret.bytes))
    }

    private static func proof(_ secret: RelaySecret, _ label: Data, _ server: Data, _ client: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label + server + client, using: SymmetricKey(data: secret.bytes)))
    }
}

/// The Mac's side of one connection: challenge out, exactly one auth in, welcome out.
public struct ServerHandshake: Sendable {
    public enum Outcome: Equatable, Sendable { case accepted(welcome: RelayFrame), rejected }

    private let secret: RelaySecret
    private let nonce: Data
    private var done = false

    public init(secret: RelaySecret, nonce: Data = RelayAuth.randomBytes(RelayAuth.nonceSize)) {
        self.secret = secret
        self.nonce = nonce
    }

    public var challenge: RelayFrame { .challenge(Data([RelayFrame.version]) + nonce) }

    public mutating func receive(_ frame: RelayFrame) -> Outcome {
        guard !done else { return .rejected }
        done = true
        guard case .auth(let clientNonce, let proof) = frame, clientNonce.count == RelayAuth.nonceSize,
              clientNonce != nonce,
              RelayAuth.valid(proof, secret, RelayAuth.clientLabel, nonce, clientNonce) else { return .rejected }
        return .accepted(welcome: .welcome(RelayAuth.serverProof(secret, server: nonce, client: clientNonce)))
    }
}

/// The iPhone's side: challenge in, auth out, welcome in (the Mac proves it knows the secret too).
public struct ClientHandshake: Sendable {
    public enum Step: Equatable, Sendable { case send(RelayFrame), authenticated, rejected }

    private enum State: Sendable { case awaitingChallenge, awaitingWelcome(server: Data), finished }

    private let secret: RelaySecret
    private let nonce: Data
    private var state = State.awaitingChallenge

    public init(secret: RelaySecret, nonce: Data = RelayAuth.randomBytes(RelayAuth.nonceSize)) {
        self.secret = secret
        self.nonce = nonce
    }

    public mutating func receive(_ frame: RelayFrame) -> Step {
        switch (state, frame) {
        case (.awaitingChallenge, .challenge(let body)):
            let server = Data(body.dropFirst())
            guard body.count == 1 + RelayAuth.nonceSize, body.first == RelayFrame.version, server != nonce else {
                state = .finished
                return .rejected
            }
            state = .awaitingWelcome(server: server)
            return .send(.auth(nonce: nonce, proof: RelayAuth.clientProof(secret, server: server, client: nonce)))
        case (.awaitingWelcome(let server), .welcome(let proof)):
            state = .finished
            return RelayAuth.valid(proof, secret, RelayAuth.serverLabel, server, nonce) ? .authenticated : .rejected
        default:
            state = .finished
            return .rejected
        }
    }
}
