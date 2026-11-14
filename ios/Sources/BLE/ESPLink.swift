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
/// Board pinning (P9, `BoardPin`): one board is pinned, with a security level; from then on only that identifier is
/// reconnected (`retrievePeripherals(withIdentifiers:)` + a pending connect, which waits for the board indefinitely)
/// and no other device is ever connected. `forgetBoard()` drops the pin and scans again.
/// Pairing by code (ARCHITECTURE §4): after board info (readable without pairing) the first protected access is a
/// read of control `…0004`. New firmware (board info version ≥ 2) refuses it until the link is encrypted and
/// authenticated, so iOS shows its pairing dialog with the board's 6 digits; the read succeeds once both sides
/// confirmed, and the board is pinned `.secure`. Old firmware (version < 2, or no control characteristic) asks for no
/// pairing, so the read proves nothing: the link holds it and reports `.legacyBoard`; only `acceptLegacyBoard()`
/// ("Vẫn ghép") pins it, as `.legacy`. A `.secure` pinned board that comes back as old firmware is refused
/// (disconnected, never ready, `.authFailed(.unverified)`); a `.legacy` pin becomes `.secure` once the board proves
/// it. Notifications are enabled only when `BoardPin` lets the setup finish. A refused read keeps the link and waits
/// for `retryPairing()` (an unpinned board, the Pair screen) or reads again after `authRetryDelay` (the pinned board,
/// whose bond was lost). `onPairingEvent` reports the steps to the Pair screen.
/// The central is created by `activate()` (or at init with `startCentral`), since creating it asks for the Bluetooth
/// permission: the Permissions screen asks first.
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
    /// Pairing steps for the Pair screen (BLE queue). Set before `activate()`.
    var onPairingEvent: (@Sendable (PairingLinkEvent) -> Void)?
    /// The central's state changed (the Bluetooth permission was answered, Bluetooth toggled) (BLE queue)
    var onCentralUpdate: (@Sendable () -> Void)?

    // BoardLink streams (broadcast; sent on the BLE queue)
    private let stateEvents = Broadcast<BoardState>()
    private let audioEvents = Broadcast<Data>(bufferingPolicy: .bufferingNewest(BoardProtocol.audioBufferPackets))
    private let controlEvents = Broadcast<BoardControl>()
    /// `currentState` and `info`, read from any thread
    private let shared = OSAllocatedUnfairLock(initialState: (state: BoardState.off,
                                                              info: BoardLabel.info(from: nil),
                                                              awaitingPairing: false))

    var state: AsyncStream<BoardState> { stateEvents.stream() }
    var audio: AsyncStream<Data> { audioEvents.stream() }
    var control: AsyncStream<BoardControl> { controlEvents.stream() }
    var currentState: BoardState { shared.withLock { $0.state } }
    var info: BoardInfo { shared.withLock { $0.info } }

    private let queue = DispatchQueue(label: "esp.ble", qos: .userInteractive)
    /// Nil until `activate()` (BLE queue)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var textCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    /// The board-info characteristic while its value is being read during setup
    private var infoCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    /// The board info read during setup, kept until the protected read succeeded
    private var pendingInfo: Data?
    /// The protected read of control `…0004` is out (BLE queue)
    private var authReading = false
    /// The protected read was refused on this link; waiting for a retry (BLE queue)
    private var authRefused = false
    private var authRetry: DispatchWorkItem?
    /// The pinned board's read is retried after this long when refused (the board rate-limits pairing requests)
    static let authRetryDelay: TimeInterval = 15
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

    /// `startCentral: false` waits for `activate()`: creating the central asks for the Bluetooth permission
    init(startCentral: Bool = true) {
        let store = BoardPinStore()
        pinStore = store
        pin = BoardPin(pinned: store.load())   // a pin saved without a level loads as legacy
        super.init()
        if startCentral { activate() }
    }

    /// Creates the central (once): iOS asks for the Bluetooth permission now if it was never answered
    func activate() {
        queue.async { [self] in
            guard central == nil else { return }
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    /// Whether a board was pinned (paired) before
    var hasPinnedBoard: Bool { pinStore.load() != nil }

    /// "Thử lại" on the Pair screen: reads the protected characteristic again when the link is still up after a
    /// refusal. True when it did (the screen waits for the code again); false when the link is scanning.
    @discardableResult
    func retryPairing() -> Bool {
        let awaiting = shared.withLock { $0.awaitingPairing }
        queue.async { [self] in
            // A board the user said "Huỷ" to may be found again
            pin.clearDeclined()
            if authRefused, let peripheral, peripheral.state == .connected {
                readProtected(peripheral)
                return
            }
            // Scanning without a pin: start the scan over so a board seen (and ignored) before is reported again
            let idle = peripheral.map { $0.state == .disconnected } ?? true
            if pin.pinned == nil, idle, let central, central.state == .poweredOn {
                central.stopScan()
                startScan()
            }
        }
        return awaiting
    }

    /// The user's answer about an old-firmware board (`PairingLinkEvent.legacyBoard`): true ("Vẫn ghép") finishes the
    /// setup and pins it as legacy; false ("Huỷ") drops it and ignores it until `retryPairing()` or `forgetBoard()`.
    func answerLegacyBoard(accept: Bool) {
        queue.async { [self] in
            guard let peripheral, peripheral.state == .connected else { return }
            if accept {
                guard pin.acceptLegacy() else { return }
                Diag.log("ble: old-firmware board accepted by the user")
                completeSetup(peripheral)
            } else {
                guard pin.declineLegacy() != nil else { return }
                Diag.log("ble: old-firmware board declined by the user")
                central?.cancelPeripheralConnection(peripheral)   // didDisconnect rescans; this board is skipped
            }
        }
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
            guard let central else { return }
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
        pin.setupRestarted()
        textCharacteristic = nil
        controlCharacteristic = nil
        infoCharacteristic = nil
        audioCharacteristic = nil
        pendingInfo = nil
        authReading = false
        setAuthRefused(false)
        authRetry?.cancel()
        authRetry = nil
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
            guard let self, central?.state == .poweredOn else { return }
            startScan()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startScan() {
        retry?.cancel()
        retry = nil
        guard let central else { return }
        onPairingEvent?(.scanning)
        switch pin.reconnect {
        case .pinned(let id):
            // The pinned board only, by identifier: the connect stays pending until the board is back
            if let board = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(board, waiting: true)
                return
            }
            // The system no longer knows it (e.g. after a Bluetooth reset): scan, but only `id` is connected
        case .discover:
            if let known = central.retrieveConnectedPeripherals(withServices: [Self.service])
                .first(where: { pin.mayConnect($0.identifier) }) {
                connect(known)
                return
            }
        }
        central.scanForPeripherals(withServices: [Self.service])
        setState(.scanning)
    }

    /// `waiting`: a pending connect to the pinned board, which may be away (the screen keeps "looking for the board")
    private func connect(_ p: CBPeripheral, waiting: Bool = false) {
        guard let central else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        pin.connecting(p.identifier)
        central.connect(p)
        setState(waiting ? .scanning : .connecting)
    }

    /// The board became the pin, or its legacy pin became secure: keep it (BLE queue)
    private func keepPin(_ made: PinnedBoard?) {
        guard let made else { return }
        pinStore.save(made)
        Diag.log("ble: board pinned (\(made.security.rawValue))")
    }
}

extension ESPLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onCentralUpdate?()
        if central.state == .poweredOn {
            backoff.reset()
            startScan()
        } else {
            retry?.cancel()
            retry = nil
            linkGone()
            setState(.off)
            if central.state != .unknown && central.state != .resetting { onPairingEvent?(.bluetoothOff) }
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
        onPairingEvent?(.connected(name: peripheral.name ?? PairingMachine.defaultName))
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        scheduleRescan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A peripheral given up on (forgetBoard) is not the link any more
        guard peripheral === self.peripheral else { return }
        if let error { Diag.log("ble: disconnected: \(error)") }
        linkGone()
        onPairingEvent?(.linkLost)
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
        // Notifications wait for the protected read: on new firmware a CCCD write would need the pairing too
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.audioChar: audioCharacteristic = c
            case Self.textChar: textCharacteristic = c
            case Self.controlChar: controlCharacteristic = c
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
            boardInfoRead(peripheral, value: nil)
        }
    }

    /// Board info is known (nil: absent or unreadable): `BoardPin` decides on the protected read, consent or refusal
    /// (BLE queue)
    private func boardInfoRead(_ peripheral: CBPeripheral, value: Data?) {
        infoCharacteristic = nil
        pendingInfo = value
        let version = value.flatMap(BoardProtocol.parseBoardInfo)?.protocolVersion ?? 0
        apply(pin.boardInfo(version: version, hasControl: controlCharacteristic != nil), peripheral)
    }

    /// Carries out `BoardPin`'s decision for the current link (BLE queue)
    private func apply(_ step: BoardPin.Step, _ peripheral: CBPeripheral) {
        switch step {
        case .readProtected:
            readProtected(peripheral)
        case .finish:
            completeSetup(peripheral)
        case .askConsent:
            // Old firmware: nothing proves this is the user's board. Hold the link, nothing streams, ask the user
            Diag.log("ble: board cannot authenticate (old firmware), asking the user")
            onPairingEvent?(.legacyBoard)
        case .refuse:
            // The pinned secure board came back as old firmware (or something posing as it): never ready, never
            // a downgraded pin. The disconnect rescans with the backoff.
            Diag.log("ble: pinned board no longer authenticates, refused")
            onPairingEvent?(.authFailed(.unverified))
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    /// The link may stream: notifications, then clock, label, mic, ready (BLE queue)
    private func completeSetup(_ peripheral: CBPeripheral) {
        if let audioCharacteristic { peripheral.setNotifyValue(true, for: audioCharacteristic) }
        if let controlCharacteristic { peripheral.setNotifyValue(true, for: controlCharacteristic) }
        finishSetup(peripheral, boardInfo: pendingInfo)
        pendingInfo = nil
        onPairingEvent?(.authenticated)
    }

    /// The first protected access: read control `…0004`. New firmware makes iOS pair here (BLE queue)
    private func readProtected(_ peripheral: CBPeripheral) {
        guard let controlCharacteristic, !authReading else { return }
        authRetry?.cancel()
        authRetry = nil
        authReading = true
        setAuthRefused(false)
        onPairingEvent?(.authenticating)
        peripheral.readValue(for: controlCharacteristic)
    }

    /// The protected read answered (BLE queue)
    private func protectedReadDone(_ peripheral: CBPeripheral, error: Error?) {
        authReading = false
        if let error {
            let failure = PairingErrorMap.failure(error)
            Diag.log("ble: protected read refused (\(failure)): \(error)")
            setAuthRefused(true)
            onPairingEvent?(.authFailed(failure))
            // The pinned board lost its bond: ask again later (the board rate-limits requests); an unpinned one
            // waits for "Thử lại" on the Pair screen
            if pin.pinned != nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, authRefused, let p = self.peripheral, p.state == .connected else { return }
                    readProtected(p)
                }
                authRetry = work
                queue.asyncAfter(deadline: .now() + Self.authRetryDelay, execute: work)
            }
            return
        }
        Diag.log("ble: protected read ok")
        apply(pin.accessGranted(), peripheral)
    }

    private func setAuthRefused(_ refused: Bool) {
        authRefused = refused
        shared.withLock { $0.awaitingPairing = refused }
    }

    /// Board info known (nil: absent or unreadable): clock, label, mic, keepalive, then ready (BLE queue)
    private func finishSetup(_ peripheral: CBPeripheral, boardInfo value: Data?) {
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
            boardInfoRead(peripheral, value: error == nil ? characteristic.value : nil)
            return
        }
        if characteristic.uuid == Self.controlChar, authReading, characteristic === controlCharacteristic {
            // The answer to the protected read, not a notification (notifications are enabled only after it)
            protectedReadDone(peripheral, error: error)
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { Diag.log("ble: notify on \(c.uuid) failed: \(error)") }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        flush(peripheral)
    }
}
