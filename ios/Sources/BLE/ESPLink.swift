@preconcurrency import CoreBluetooth  // CBUUID, CBPeripheral: used on the BLE queue only
import Foundation
import os

/// BLE link to the ESP32 board (protocol: see firmware/main/ble_link.c and Core/BoardProtocol.swift).
/// CoreBluetooth callbacks run on a dedicated queue so audio packets never wait for the main thread.
///
/// `BoardLink` (ARCHITECTURE R4): state/audio/control streams, the board info read from `…0005` on connect, the
/// clock and the language label (kind 3) resent whenever the link becomes ready, the 20 s keepalive, a services
/// reset handled on the same connection, a generation-guarded text queue and a reconnect backoff
/// (first rescan at once, then 0.5 s → 10 s).
/// Board pinning (P9, `BoardPin`): trust on first use, the first board is pinned once its translator setup finished
/// on a link; from then on only that identifier is reconnected (`retrievePeripherals(withIdentifiers:)` + a pending
/// connect, which waits for the board indefinitely) and no other device is ever connected. `forgetBoard()` drops
/// the pin and scans again.
/// The callbacks (`onAudioPacket`, `onStateChange`, `onMicChange`) stay for ConversationEngine.
final class ESPLink: NSObject, BoardLink, @unchecked Sendable {
    typealias State = BoardState

    static let service = CBUUID(string: BoardProtocol.serviceUUID)
    static let audioChar = CBUUID(string: BoardProtocol.audioUUID)
    static let textChar = CBUUID(string: BoardProtocol.textUUID)
    static let controlChar = CBUUID(string: BoardProtocol.controlUUID)
    static let infoChar = CBUUID(string: BoardProtocol.infoUUID)

    /// Called on the BLE queue for every audio packet
    var onAudioPacket: (@Sendable (Data) -> Void)?
    var onStateChange: (@Sendable (State) -> Void)?
    /// Board mic state (off/on) when the user taps the on-screen button
    var onMicChange: (@Sendable (Bool) -> Void)?

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
    /// The translator service being set up; callbacks for an older one are ignored (BLE queue)
    private var setup = SetupGuard<CBService>()
    /// Keepalive on the control characteristic while connected (BLE queue). The board stops streaming audio after
    /// 60 s without any app write: a bonded iPhone may keep the link after the app is gone.
    private var keepalive: DispatchSourceTimer?
    /// Control byte the board takes as "the app is alive" (0...2 are mic states); see firmware/main/phone_idle.h
    static let keepaliveByte: UInt8 = 0xFF
    static let keepaliveInterval: TimeInterval = 20
    /// Last write to the board (BLE queue): a notification from the board after a longer silence (the app was
    /// suspended, so the timer did not fire) sends a keepalive right away
    private var lastWrite = DispatchTime.now()
    private static let staleWrite: UInt64 = 15_000_000_000

    /// The pinned board and the current link (BLE queue); the pin is kept in `pinStore`
    private let pinStore: BoardPinStore
    private var pin: BoardPin

    override init() {
        let store = BoardPinStore()
        pinStore = store
        pin = BoardPin(pinned: store.load())
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

    /// Forgets the pinned board (the user has a new one) and looks for a board again. A connected board is
    /// dropped first; the rescan follows its disconnect.
    func forgetBoard() {
        queue.async { [self] in
            Diag.log("ble: forgetting the pinned board")
            pinStore.save(nil)
            pin.forget()
            retry?.cancel()
            retry = nil
            guard let old = peripheral else {
                if central.state == .poweredOn { startScan() }
                return
            }
            central.cancelPeripheralConnection(old)
            linkGone()
            backoff.reset()
            if old.state == .connected { return }   // didDisconnectPeripheral rescans at once
            // A pending connect (the pinned board was away): no disconnect to wait for
            peripheral = nil
            if central.state == .poweredOn { startScan() }
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
        peripheral.writeValue(data, for: characteristic, type: type)
        lastWrite = DispatchTime.now()
    }

    /// The translator characteristics are dead (drop, Bluetooth off, services reset) (BLE queue)
    private func translatorGone() {
        stopKeepalive()
        textCharacteristic = nil
        controlCharacteristic = nil
        infoCharacteristic = nil
        textQueue.detach()
        setup.reset()
        // The next board may be older firmware: no label and Latin-only until its board info is read
        label.linkGone()
        shared.withLock { $0.info = BoardLabel.info(from: nil) }
    }

    /// The board link is gone (BLE queue)
    private func linkGone() {
        translatorGone()
        pin.linkGone()
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
        guard delay > 0 else {
            startScan()  // the first rescan after a drop is immediate
            return
        }
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
        switch pin.reconnect {
        case .pinned(let id):
            // The pinned board only, by identifier: the connect stays pending until the board is back
            if let board = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(board, waiting: true)
                return
            }
            // The system no longer knows it (e.g. after a Bluetooth reset): scan, but only `id` is connected
        case .discover:
            if let known = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
                connect(known)
                return
            }
        }
        central.scanForPeripherals(withServices: [Self.service])
        setState(.scanning)
    }

    /// `waiting`: a pending connect to the pinned board, which may be away (the screen keeps "looking for the board")
    private func connect(_ p: CBPeripheral, waiting: Bool = false) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        pin.connecting(p.identifier)
        central.connect(p)
        setState(waiting ? .scanning : .connecting)
    }

    /// The first board finished its setup and became the pin: keep it (BLE queue)
    private func keepPin(_ id: UUID?) {
        guard let id else { return }
        pinStore.save(id)
        Diag.log("ble: board pinned")
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
        // With a pinned board, any other device advertising the board service is ignored
        guard pin.mayConnect(peripheral.identifier) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else {
            central.cancelPeripheralConnection(peripheral)   // given up on (forgetBoard) while it was pending
            return
        }
        if currentState == .scanning { setState(.connecting) }   // the pending connect to the pinned board
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        scheduleRescan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A peripheral given up on (forgetBoard) is not the link any more
        guard peripheral === self.peripheral else { return }
        linkGone()
        scheduleRescan()
    }
}

extension ESPLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        for s in peripheral.services ?? [] where s.uuid == Self.service {
            setup.begin(s)
            peripheral.discoverCharacteristics([Self.audioChar, Self.textChar, Self.controlChar, Self.infoChar], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Only the service being set up: a discovery from before a services reset or a drop must not mark its dead
        // characteristics ready (Review Focus 1)
        guard service.uuid == Self.service, peripheral === self.peripheral, setup.isCurrent(service) else { return }
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
        // A subtitle sent from now on is kept and written once the clock and the label are out
        if let textCharacteristic { textQueue.attach(textCharacteristic, ready: false) }
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
            let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
            for frame in label.readyFrames(maxWrite: maxWrite) {
                write(peripheral, frame, for: textCharacteristic, type: .withResponse)
            }
            // Then whatever subtitle came in during setup
            textQueue.markReady()
            flush(peripheral)
        }
        // Turn the board mic on right away: the conversation starts with no taps
        if let controlCharacteristic {
            write(peripheral, Data([1]), for: controlCharacteristic, type: .withResponse)
            startKeepalive()
        }
        backoff.reset()
        keepPin(pin.setupFinished())
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
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
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
