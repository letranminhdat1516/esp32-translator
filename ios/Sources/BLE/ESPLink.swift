@preconcurrency import CoreBluetooth  // CBUUID, CBPeripheral: used on the BLE queue only
import Foundation
import os

/// BLE link to the ESP32 board (protocol: see firmware/main/ble_link.c and Core/BoardProtocol.swift).
/// CoreBluetooth callbacks run on a dedicated queue so audio packets never wait for the main thread.
/// The board's Claude service is used only by the Claude relay (ClaudeRelayService): the translator never reads it.
///
/// `BoardLink` (ARCHITECTURE R4): state/audio/control streams, the board info read from `…0005` on connect, the
/// clock and the language label (kind 3) resent whenever the link becomes ready, the 20 s keepalive, a services
/// reset handled on the same connection, a generation-guarded text queue and a reconnect backoff (0.5 s → 10 s).
/// The callbacks (`onAudioPacket`, `onStateChange`, `onMicChange`) stay for ConversationEngine.
final class ESPLink: NSObject, BoardLink, @unchecked Sendable {
    typealias State = BoardState

    static let service = CBUUID(string: BoardProtocol.serviceUUID)
    static let audioChar = CBUUID(string: BoardProtocol.audioUUID)
    static let textChar = CBUUID(string: BoardProtocol.textUUID)
    static let controlChar = CBUUID(string: BoardProtocol.controlUUID)
    static let infoChar = CBUUID(string: BoardProtocol.infoUUID)

    static let claudeService = CBUUID(string: "A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeRequest = CBUUID(string: "A7C00011-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeAnswer = CBUUID(string: "A7C00012-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeVoice = CBUUID(string: "A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

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

    // BoardLink streams (broadcast; sent on the BLE queue)
    private let stateEvents = Broadcast<BoardState>()
    private let audioEvents = Broadcast<Data>(bufferingPolicy: .bufferingNewest(BoardProtocol.audioBufferPackets))
    private let controlEvents = Broadcast<BoardControl>()
    /// `currentState` and `info`, read from any thread
    private let shared = OSAllocatedUnfairLock(initialState: (state: BoardState.off,
                                                              info: BoardLabel.info(from: nil)))

    var state: AsyncStream<BoardState> { stateEvents.stream() }
    var audio: AsyncStream<Data> { audioEvents.stream() }
    var control: AsyncStream<BoardControl> { controlEvents.stream() }
    var currentState: BoardState { shared.withLock { $0.state } }
    var info: BoardInfo { shared.withLock { $0.info } }

    private let queue = DispatchQueue(label: "esp.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var textCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    /// The board-info characteristic while its value is being read during setup
    private var infoCharacteristic: CBCharacteristic?
    /// Subtitle chunks not yet written, tied to the current text characteristic (BLE queue)
    private var textQueue = BoardWriteQueue<CBCharacteristic>()
    /// The language label to resend on ready (BLE queue)
    private var label = BoardLabel()
    /// Pause before the next scan after a drop or a failed connect (BLE queue)
    private var backoff = ReconnectBackoff()
    private var retry: DispatchWorkItem?
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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Sends text to the screen (`BoardProtocol.frameText`). A new message replaces an unsent one (the board resets
    /// its buffer on a first chunk). A label (kind 3) is remembered and resent on every ready; it is sent only to a
    /// board with board info (older firmware shows unknown kinds as subtitles).
    func send(text: String, kind: TextKind) {
        queue.async { [self] in
            var shown = text
            if kind == .label {
                guard let cut = label.send(text) else { return }
                shown = cut
            }
            guard let peripheral else { return }
            let chunks = BoardProtocol.frameText(shown, kind: kind,
                                                 maxWrite: peripheral.maximumWriteValueLength(for: .withoutResponse))
            guard textQueue.replace(chunks) else { return }
            flush(peripheral)
        }
    }

    /// `BoardLink.sendText`: same as `send(text:kind:)`
    func sendText(_ text: String, kind: TextKind) {
        send(text: text, kind: kind)
    }

    /// Re-sends the wall clock (after a significant time change); does nothing until the link is set up
    func sendTime() {
        queue.async { [self] in
            guard let peripheral, peripheral.state == .connected, let textCharacteristic else { return }
            write(peripheral, BoardProtocol.timeFrame(), for: textCharacteristic, type: .withResponse)
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

    /// The translator characteristics are dead (drop, Bluetooth off, services reset) (BLE queue)
    private func translatorGone() {
        stopKeepalive()
        textCharacteristic = nil
        controlCharacteristic = nil
        infoCharacteristic = nil
        textQueue.detach()
    }

    /// The board link is gone (BLE queue)
    private func linkGone() {
        translatorGone()
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

    private func flush(_ peripheral: CBPeripheral) {
        textQueue.drain(canSend: { peripheral.canSendWriteWithoutResponse }) { characteristic, chunk in
            write(peripheral, chunk, for: characteristic, type: .withoutResponse)
        }
    }

    private func setState(_ state: State) {
        shared.withLock { $0.state = state }
        stateEvents.send(state)
        onStateChange?(state)
    }

    /// After a drop or a failed connect: scan again after the backoff (BLE queue)
    private func scheduleRescan() {
        retry?.cancel()
        let delay = backoff.nextDelay()
        Diag.log("ble: rescan in \(delay) s")
        setState(.scanning)
        let work = DispatchWorkItem { [weak self] in
            guard let self, central.state == .poweredOn else { return }
            startScan()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startScan() {
        retry?.cancel()
        retry = nil
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
            backoff.reset()
            startScan()
        } else {
            retry?.cancel()
            retry = nil
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
        scheduleRescan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        linkGone()
        scheduleRescan()
    }
}

extension ESPLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            switch s.uuid {
            case Self.service:
                peripheral.discoverCharacteristics([Self.audioChar, Self.textChar, Self.controlChar, Self.infoChar],
                                                   for: s)
            case Self.claudeService where claudeRequestChar == nil:
                // Once per connection: a translator services reset rediscovers with the relay's characteristics kept
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
        var info: CBCharacteristic?
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.audioChar: peripheral.setNotifyValue(true, for: c)
            case Self.textChar: textCharacteristic = c
            case Self.controlChar:
                controlCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            case Self.infoChar: info = c
            default: break
            }
        }
        // Board info first (absent on older firmware): it decides whether the label is sent
        if let info {
            infoCharacteristic = info
            peripheral.readValue(for: info)
        } else {
            finishSetup(peripheral, boardInfo: nil)
        }
    }

    /// Board info known (nil: absent or unreadable): clock, label, mic, keepalive, then ready (BLE queue)
    private func finishSetup(_ peripheral: CBPeripheral, boardInfo value: Data?) {
        infoCharacteristic = nil
        let boardInfo = BoardLabel.info(from: value)
        shared.withLock { $0.info = boardInfo }
        label.boardInfo(parsed: value.flatMap(BoardProtocol.parseBoardInfo) != nil)
        Diag.log("ble: board info v\(boardInfo.protocolVersion) fonts \(boardInfo.fontSets)")
        // Set the board clock, then the label it forgot (with response: never dropped or replaced by a subtitle)
        if let textCharacteristic {
            // Subtitles are queued only from here on, after the clock and the label
            textQueue.attach(textCharacteristic)
            let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
            for frame in label.readyFrames(maxWrite: maxWrite) {
                write(peripheral, frame, for: textCharacteristic, type: .withResponse)
            }
        }
        // Turn the board mic on right away: the conversation starts with no taps
        if let controlCharacteristic {
            write(peripheral, Data([1]), for: controlCharacteristic, type: .withResponse)
            startKeepalive()
        }
        backoff.reset()
        setState(.ready)
    }

    /// The board changed its GATT table (e.g. new firmware on a bonded phone): the translator characteristics are
    /// dead. Discover again and redo the setup (board info, clock, label, mic) on the same connection.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service })
        else { return }
        Diag.log("ble: board services changed, setting up again")
        translatorGone()
        setState(.connecting)
        peripheral.discoverServices([Self.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.infoChar {
            // Only the read of the current setup (a services reset may have replaced it)
            guard characteristic === infoCharacteristic else { return }
            if let error { Diag.log("ble: board info read failed: \(error)") }
            finishSetup(peripheral, boardInfo: error == nil ? characteristic.value : nil)
            return
        }
        keepaliveIfStale(peripheral)
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Self.audioChar {
            onAudioPacket?(value)
            audioEvents.send(value)
        } else if characteristic.uuid == Self.controlChar, let state = value.first {
            onMicChange?(state != 0)
            controlEvents.send(.micChanged(state != 0))
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
        if let error, c.uuid == Self.textChar {
            // Only the current link's queue: a stale write may fail after a services reset or a reconnect
            Diag.log("ble: text write failed: \(error)")
            textQueue.writeFailed(on: c)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        flush(peripheral)
    }
}
