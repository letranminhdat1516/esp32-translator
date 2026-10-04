import ClaudeBoardCore
@preconcurrency import CoreBluetooth
import Foundation

/// Connects to the translator board (it advertises the translator service) and talks to its Claude service.
/// The Claude characteristics need an encrypted, bonded link (Just Works); the request characteristic only
/// accepts write-with-response from the connection that subscribed to the answer characteristic. So the link
/// is "ready" only once the answer subscription is confirmed.
/// All mutable state is touched only on `queue`.
final class BoardLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let translatorService = CBUUID(string: "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeService = CBUUID(string: "A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let requestChar = CBUUID(string: "A7C00011-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let answerChar = CBUUID(string: "A7C00012-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    var onAnswer: (@Sendable (Answer) -> Void)?
    var onConnectionChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "claude-board.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var request: CBCharacteristic?
    private var subscribed = false
    private var subscribeRetried = false
    private let knownKey = "boardIdentifier"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Subscribed to the answer characteristic and request characteristic known.
    var isReady: Bool { queue.sync { request != nil && subscribed } }

    func send(_ message: BoardMessage) {
        queue.async { [self] in
            guard let peripheral, let request, subscribed else { return }
            // Chunk to ATT MTU - 3 (the without-response limit) even though we write with response: the
            // with-response limit is 512 (long writes), larger than the board accepts in one write.
            let size = peripheral.maximumWriteValueLength(for: .withoutResponse)
            for chunk in BoardMessage.chunks(message.encode(), maxChunk: size) {
                peripheral.writeValue(chunk, for: request, type: .withResponse)
            }
        }
    }

    private func log(_ s: String) { FileHandle.standardError.write(Data("[ble] \(s)\n".utf8)) }

    private func scan() {
        if let id = UserDefaults.standard.string(forKey: knownKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: [Self.translatorService])
            log("scanning")
        }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { scan() } else { log("bluetooth state \(c.state.rawValue)") }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected \(p.identifier)")
        subscribed = false
        subscribeRetried = false
        p.discoverServices([Self.claudeService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error.map { "\($0)" } ?? "unknown")")
        queue.asyncAfter(deadline: .now() + 2) { self.scan() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        request = nil
        subscribed = false
        log("disconnected")
        onConnectionChange?(false)
        queue.asyncAfter(deadline: .now() + 2) { self.scan() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.claudeService }) else {
            log("board has no Claude service (old firmware?); dropping connection")
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.requestChar, Self.answerChar], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        var answer: CBCharacteristic?
        for c in s.characteristics ?? [] {
            if c.uuid == Self.requestChar { request = c }
            if c.uuid == Self.answerChar { answer = c }
        }
        guard request != nil, let answer else {
            log("Claude characteristics missing; dropping connection")
            central.cancelPeripheralConnection(p)
            return
        }
        // Ready is declared only when the subscription is confirmed (see didUpdateNotificationStateFor).
        p.setNotifyValue(true, for: answer)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.answerChar else { return }
        if let error {
            let code = (error as NSError).code
            let authIssue = (error as NSError).domain == CBATTErrorDomain
                && (code == CBATTError.insufficientAuthentication.rawValue
                    || code == CBATTError.insufficientEncryption.rawValue)
            log("subscribe failed: \(error)")
            if authIssue && !subscribeRetried {
                subscribeRetried = true
                log("link not encrypted yet; waiting for pairing, retrying subscribe in 3 s")
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    guard peripheral === p, p.state == .connected else { return }
                    p.setNotifyValue(true, for: c)
                }
            } else {
                log("subscribe failed and not retryable; dropping connection to reconnect")
                central.cancelPeripheralConnection(p)
            }
            return
        }
        guard c.isNotifying else {
            subscribed = false
            return
        }
        subscribed = true
        UserDefaults.standard.set(p.identifier.uuidString, forKey: knownKey)
        log("ready")
        onConnectionChange?(true)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { log("write failed: \(error)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == Self.answerChar, let v = c.value, let a = Answer.decode(v) { onAnswer?(a) }
    }
}

extension BoardLink: BoardLinking {}
