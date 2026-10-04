import CoreBluetooth
import Foundation

/// BLE link to the ESP32 board (protocol: see firmware/main/ble_link.c).
/// CoreBluetooth callbacks run on a dedicated queue so audio packets never wait for the main thread.
/// The board's Claude service is used only by the Claude relay (ClaudeRelayService): the translator never reads it.
final class ESPLink: NSObject, @unchecked Sendable {
    enum State: Equatable { case off, scanning, connecting, ready }

    static let service = CBUUID(string: "A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let audioChar = CBUUID(string: "A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let textChar = CBUUID(string: "A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let controlChar = CBUUID(string: "A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    static let claudeService = CBUUID(string: "A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeRequest = CBUUID(string: "A7C00011-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeAnswer = CBUUID(string: "A7C00012-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeVoice = CBUUID(string: "A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    enum TextKind: UInt8 { case subtitle = 0, status = 1, time = 2 }

    /// Called on the BLE queue for every audio packet
    var onAudioPacket: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (State) -> Void)?
    /// Board mic state (off/on) when the user taps the on-screen button
    var onMicChange: (@Sendable (Bool) -> Void)?

    /// Claude relay (all on the BLE queue): the write size once the Claude characteristics are found, nil when the
    /// board link is gone; the answer subscription state; board inputs; board voice audio (ADPCM)
    var onClaudeReady: (@Sendable (Int?) -> Void)?
    var onClaudeSubscribed: (@Sendable (Bool) -> Void)?
    var onClaudeInput: (@Sendable (Data) -> Void)?
    var onClaudeVoice: (@Sendable (Data) -> Void)?
    /// The board may have just given this link the translator role (the first translator write on a link, a write
    /// after a silence the board takes for a gone app, or a control notification): the relay repeats its hello,
    /// which the board takes only on the link holding that role
    var onTranslatorActive: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "esp.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var textCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    /// Keepalive on the control characteristic while connected (BLE queue). The board stops streaming audio after
    /// 60 s without any app write: a bonded iPhone keeps the link for notifications (ANCS) after the app is gone.
    private var keepalive: DispatchSourceTimer?
    /// Control byte the board takes as "the app is alive" (0...2 are mic states); see firmware/main/phone_idle.h
    static let keepaliveByte: UInt8 = 0xFF
    static let keepaliveInterval: TimeInterval = 20
    /// Last write to the board (BLE queue): a notification from the board after a longer silence (the app was
    /// suspended, so the timer did not fire) sends a keepalive right away
    private var lastWrite = DispatchTime.now()
    private static let staleWrite: UInt64 = 15_000_000_000
    /// A write after this much silence may have given the role back (the board drops it after 60 s: phone_idle.h)
    private static let roleGap: UInt64 = 45_000_000_000
    private var translatorWritten = false

    private var claudeRequestChar: CBCharacteristic?
    private var claudeAnswerChar: CBCharacteristic?
    private var claudeVoiceChar: CBCharacteristic?
    private var answerRetried = false
    /// The relay's last setClaudeSubscribed (a delayed auth retry must not resubscribe after an unsubscribe)
    private var claudeAnswerWanted = false

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

    /// Re-sends the wall clock (after a significant time change); does nothing until the link is set up
    func sendTime() {
        queue.async { [self] in
            guard let peripheral, peripheral.state == .connected, let textCharacteristic else { return }
            write(peripheral, Self.timePayload(), for: textCharacteristic, type: .withResponse)
        }
    }

    func setBoardMic(_ on: Bool) {
        queue.async { [self] in
            guard let peripheral, let controlCharacteristic else { return }
            write(peripheral, Data([on ? 1 : 0]), for: controlCharacteristic, type: .withResponse)
        }
    }

    /// The board's Claude answers (and with them the relay role, after the hello). Encrypted: the board is bonded.
    func setClaudeSubscribed(_ on: Bool) {
        queue.async { [self] in
            claudeAnswerWanted = on
            guard let peripheral, let c = claudeAnswerChar else { return }
            answerRetried = false
            peripheral.setNotifyValue(on, for: c)
        }
    }

    func setClaudeVoice(_ on: Bool) {
        queue.async { [self] in
            guard let peripheral, let c = claudeVoiceChar else { return }
            peripheral.setNotifyValue(on, for: c)
        }
    }

    /// One relay chunk ([flags][payload]), with response so none is dropped or reordered. Not a translator write:
    /// it neither keeps the translator role nor counts for the keepalive.
    func writeClaude(_ chunk: Data) {
        queue.async { [self] in
            guard let peripheral, let c = claudeRequestChar else { return }
            peripheral.writeValue(chunk, for: c, type: .withResponse)
        }
    }

    /// BLE queue. A dispatch timer, not a run-loop one: it keeps firing in the background (bluetooth-central / audio)
    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepaliveInterval, repeating: Self.keepaliveInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let peripheral, peripheral.state == .connected, let controlCharacteristic else { return }
            write(peripheral, Data([Self.keepaliveByte]), for: controlCharacteristic, type: .withResponse)
        }
        timer.resume()
        keepalive = timer
    }

    /// Every write to the board goes through here (BLE queue)
    private func write(_ peripheral: CBPeripheral, _ data: Data, for characteristic: CBCharacteristic,
                       type: CBCharacteristicWriteType) {
        let now = DispatchTime.now()
        let gap = now.uptimeNanoseconds &- lastWrite.uptimeNanoseconds
        peripheral.writeValue(data, for: characteristic, type: type)
        lastWrite = now
        if !translatorWritten || gap > Self.roleGap {
            translatorWritten = true
            onTranslatorActive?()
        }
    }

    /// The board link is gone (BLE queue)
    private func linkGone() {
        stopKeepalive()
        textCharacteristic = nil
        controlCharacteristic = nil
        pendingChunks.removeAll()
        translatorWritten = false
        let hadClaude = claudeRequestChar != nil
        claudeRequestChar = nil
        claudeAnswerChar = nil
        claudeVoiceChar = nil
        claudeAnswerWanted = false
        if hadClaude { onClaudeReady?(nil) }
    }

    /// The board notified something: if the app has not written for 15 s (it was suspended), prove it is alive
    private func keepaliveIfStale(_ peripheral: CBPeripheral) {
        guard let controlCharacteristic,
              DispatchTime.now().uptimeNanoseconds &- lastWrite.uptimeNanoseconds > Self.staleWrite else { return }
        Diag.log("ble: keepalive after \((DispatchTime.now().uptimeNanoseconds &- lastWrite.uptimeNanoseconds) / 1_000_000_000) s without a write")
        write(peripheral, Data([Self.keepaliveByte]), for: controlCharacteristic, type: .withResponse)
    }

    private func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    private func flush(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        while !pendingChunks.isEmpty && peripheral.canSendWriteWithoutResponse {
            write(peripheral, pendingChunks.removeFirst(), for: characteristic, type: .withoutResponse)
        }
    }

    /// Wall clock for the board's lock face: one text write, kind 2, ASCII "<unix seconds> <UTC offset minutes>"
    /// (same format as the Mac's Claude time message; see firmware/main/clock.h)
    static func timePayload(at date: Date = Date(), in timeZone: TimeZone = .current) -> Data {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let offset = timeZone.secondsFromGMT(for: date) / 60
        return Data([0x03, TextKind.time.rawValue]) + Data("\(seconds) \(offset)".utf8)
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
            linkGone()
            setState(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service, Self.claudeService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        linkGone()
        startScan()
    }
}

extension ESPLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            switch s.uuid {
            case Self.service:
                peripheral.discoverCharacteristics([Self.audioChar, Self.textChar, Self.controlChar], for: s)
            case Self.claudeService:
                peripheral.discoverCharacteristics([Self.claudeRequest, Self.claudeAnswer, Self.claudeVoice], for: s)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if service.uuid == Self.claudeService {
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case Self.claudeRequest: claudeRequestChar = c
                case Self.claudeAnswer: claudeAnswerChar = c
                case Self.claudeVoice: claudeVoiceChar = c
                default: break
                }
            }
            if claudeRequestChar != nil && claudeAnswerChar != nil {
                onClaudeReady?(peripheral.maximumWriteValueLength(for: .withoutResponse))
            }
            return
        }
        guard service.uuid == Self.service else { return }
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
        // Set the board clock (with response: never dropped or replaced by a subtitle write)
        if let textCharacteristic {
            write(peripheral, Self.timePayload(), for: textCharacteristic, type: .withResponse)
        }
        // Turn the board mic on right away: the conversation starts with no taps
        if let controlCharacteristic {
            write(peripheral, Data([1]), for: controlCharacteristic, type: .withResponse)
            startKeepalive()
        }
        setState(.ready)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        keepaliveIfStale(peripheral)
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.audioChar {
            onAudioPacket?(value)
        } else if characteristic.uuid == Self.controlChar, let state = value.first {
            onMicChange?(state != 0)
            onTranslatorActive?()   // the board notifies the control value when it gives the role back
        } else if characteristic.uuid == Self.claudeAnswer {
            onClaudeInput?(value)
        } else if characteristic.uuid == Self.claudeVoice {
            onClaudeVoice?(value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.claudeAnswer else { return }
        if let error {
            let ns = error as NSError
            let auth = ns.domain == CBATTErrorDomain && (ns.code == CBATTError.insufficientAuthentication.rawValue
                                                          || ns.code == CBATTError.insufficientEncryption.rawValue)
            Diag.log("claude answers subscribe failed: \(error)")
            if auth && !answerRetried {           // iOS pairs / re-encrypts, then the retry succeeds
                answerRetried = true
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    guard self.peripheral === peripheral, peripheral.state == .connected, claudeAnswerWanted,
                          claudeAnswerChar === c else {
                        onClaudeSubscribed?(false)
                        return
                    }
                    peripheral.setNotifyValue(true, for: c)
                }
                return
            }
            onClaudeSubscribed?(false)
            return
        }
        onClaudeSubscribed?(c.isNotifying)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error, c.uuid == Self.claudeRequest { Diag.log("claude relay write failed: \(error)") }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let textCharacteristic { flush(peripheral, textCharacteristic) }
    }
}
