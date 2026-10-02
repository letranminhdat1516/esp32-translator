import CoreBluetooth
import Foundation

/// BLE link to the ESP32 board (protocol: see firmware/main/ble_link.c).
/// CoreBluetooth callbacks run on a dedicated queue so audio packets never wait for the main thread.
final class ESPLink: NSObject, @unchecked Sendable {
    enum State: Equatable { case off, scanning, connecting, ready }

    static let service = CBUUID(string: "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let audioChar = CBUUID(string: "A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let textChar = CBUUID(string: "A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let controlChar = CBUUID(string: "A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    enum TextKind: UInt8 { case subtitle = 0, status = 1 }

    /// Called on the BLE queue for every audio packet
    var onAudioPacket: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (State) -> Void)?
    /// Board mic state (off/on) when the user taps the on-screen button
    var onMicChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "esp.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var textCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []

    /// The round screen fits about 5 lines of 36 px text, so only the tail is sent
    private let maxTextBytes = 150

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Sends text to the screen. A new message replaces an unsent one (the board resets its buffer on a first chunk).
    func send(text: String, kind: TextKind) {
        queue.async { [self] in
            guard let peripheral, let textCharacteristic else { return }
            let payload = Data(Self.tail(of: text, maxBytes: maxTextBytes).utf8)
            let size = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse)) - 2
            var chunks: [Data] = []
            var offset = 0
            repeat {
                let end = min(offset + size, payload.count)
                var flags: UInt8 = 0
                if offset == 0 { flags |= 0x01 }
                if end == payload.count { flags |= 0x02 }
                chunks.append(Data([flags, kind.rawValue]) + payload[offset..<end])
                offset = end
            } while offset < payload.count
            pendingChunks = chunks
            flush(peripheral, textCharacteristic)
        }
    }

    func setBoardMic(_ on: Bool) {
        queue.async { [self] in
            guard let peripheral, let controlCharacteristic else { return }
            peripheral.writeValue(Data([on ? 1 : 0]), for: controlCharacteristic, type: .withResponse)
        }
    }

    private func flush(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        while !pendingChunks.isEmpty && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(pendingChunks.removeFirst(), for: characteristic, type: .withoutResponse)
        }
    }

    /// Takes the tail of a string within a byte budget, never splitting a character
    private static func tail(of text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = Substring(text)
        while result.utf8.count > maxBytes { result = result.dropFirst() }
        if let space = result.firstIndex(of: " ") { result = result[result.index(after: space)...] }
        return "…" + result
    }

    private func setState(_ state: State) { onStateChange?(state) }

    private func startScan() {
        if let known = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            connect(known)
            return
        }
        central.scanForPeripherals(withServices: [Self.service])
        setState(.scanning)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
        setState(.connecting)
    }
}

extension ESPLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        } else {
            setState(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        textCharacteristic = nil
        controlCharacteristic = nil
        pendingChunks.removeAll()
        startScan()
    }
}

extension ESPLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
        peripheral.discoverCharacteristics([Self.audioChar, Self.textChar, Self.controlChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.audioChar: peripheral.setNotifyValue(true, for: c)
            case Self.textChar: textCharacteristic = c
            case Self.controlChar:
                controlCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        // Turn the board mic on right away: the conversation starts with no taps
        if let controlCharacteristic {
            peripheral.writeValue(Data([1]), for: controlCharacteristic, type: .withResponse)
        }
        setState(.ready)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.audioChar {
            onAudioPacket?(value)
        } else if characteristic.uuid == Self.controlChar, let state = value.first {
            onMicChange?(state != 0)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let textCharacteristic { flush(peripheral, textCharacteristic) }
    }
}
