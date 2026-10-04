# Phase 5: Relay Through the iPhone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Away from the Mac (out of Bluetooth range), the board keeps working as the Claude Code companion: the iPhone app relays the board's Claude messages between the board (BLE) and the Mac daemon (an authenticated WebSocket over Tailscale), byte-for-byte the same messages as the direct link. The board and the daemon both prefer the direct BLE link and fall back to the relay. Voice commands still work: the iPhone transcribes the board audio and relays only the text.

**Architecture:** A new shared Swift package `relay/` (`ClaudeRelay`, macOS 14 + iOS 26) holds everything both ends must agree on. That is the BLE chunk framing (moved from `BoardMessage.chunks`), the link hello, the relay frame codec, the HMAC-SHA256 challenge-response handshake, the pairing payload, Tailscale address rules, the Network.framework WebSocket server and client, and the iPhone's pure relay state machine (`RelayBridge`). All of it is tested with `swift test` on the Mac, without Tailscale, over loopback. The daemon gets a `BoardRouter` that implements the existing `BoardLinking`. It picks the direct BLE link when it is ready and the relay otherwise. When an input arrives over the relay, the board has already moved, so the router follows. A `RelayVoiceEngine` plugs the iPhone's transcription into the unchanged `VoiceHub` as one more `VoiceEngine`. The daemon listens only on its Tailscale address. It re-checks that address on every network change and refuses to listen anywhere else. The board learns who is who from an explicit hello message (kind 9) on its request characteristic: "mac" from the daemon, "relay" from the iPhone app. A pure, host-tested model (`claude_link.c`) decides the active Claude link: the Mac if one said hello, otherwise the relay. The relay must be the connection that holds the translator app's audio role. The GATT table does not change.

**Tech Stack:** Swift 6 packages with Swift Testing (`relay/`, `mac/`), Network.framework (`NWListener` / `NWConnection` with `NWProtocolWebSocket`), CryptoKit (HMAC-SHA256), CoreImage (`CIQRCodeGenerator`, `CIDetector` in tests), Security (iOS Keychain), AVFoundation (QR scanner), Speech `SpeechAnalyzer` / `DictationTranscriber` (iOS 26), XcodeGen, ESP-IDF 5.5 + NimBLE (C, host tests with `cc`), Python 3 + `bleak` for the on-device fake-relay script.

**Spec:** `docs/superpowers/specs/2026-10-04-board-modes-claude-sessions-design.md`, section "Phase 5: relay through the iPhone (away from the Mac)" and the Testing line "relay with the Mac out of range". The decisions agreed in conversation are copied into Global Constraints below and are binding. For conventions and the existing wire format, see the Phase 2 and Phase 3 plans (`docs/superpowers/plans/2026-10-04-phase2-claude-sessions.md`, `docs/superpowers/plans/2026-10-04-phase3-voice-commands.md`). Phase 4 (`docs/superpowers/plans/2026-10-05-phase4-ancs.md`) edits `firmware/main/ble_link.c` at the same time. **Firmware Tasks 6–7 start only after Phase 4 is merged into this branch.** Line numbers below come from the pre-Phase-4 tree, so locate every edit by its quoted content.

## Global Constraints

- Spec (verbatim): "The Mac daemon listens on its Tailscale address only, with a shared secret generated at install; the installer prints a QR code (address + secret) that the iPhone app scans once." "The iPhone app relays Claude messages between the board (BLE) and the Mac (WebSocket over Tailscale), using the same message format as the direct link. It does not interpret or answer anything itself." "Path selection: the board prefers the direct Mac link, otherwise the relay; the daemon prefers direct BLE, otherwise the relay." "Voice away from the Mac: the iPhone transcribes the board audio and relays text only." "Security: WireGuard (Tailscale) + secret; the port is not exposed to the internet; all existing id checks apply; never auto-approve." "The iPhone app must be running (it runs in the background for the translator anyway). Free developer accounts require reinstalling the app every 7 days."
- Listening (agreed): the daemon binds its WebSocket listener to one address only: the Mac's Tailscale address, found by an interface scan (`getifaddrs`). It must be a `utun*` interface holding an IPv4 address in `100.64.0.0/10` or an IPv6 address in `fd7a:115c:a1e0::/48`; IPv4 is preferred. No Tailscale address means no listener (the log says why). The daemon never binds `0.0.0.0`, `::`, a LAN address or loopback. Each accepted connection's remote address must also be a Tailscale address, or it is closed before any byte is read. Port `RelayConfig.port = 47821`. The address is checked again on every network path change (`NWPathMonitor`, event-driven, no polling), and the listener is rebound when the address changes. Tests bind loopback through an injected policy and never need Tailscale.
- Secret (agreed): 32 random bytes, stored base64url (no padding) plus `\n` in `~/.claude-board/relay.secret`, a regular file with mode `0600`, owned by the user, in the `0700` directory. The daemon refuses a secret file that is a symlink, has any group/other permission bit, or is owned by someone else, and the relay then stays off. The secret is created by `claude-board --pair`, which `mac/install.sh` runs. `--pair --new-secret` rotates it. The secret never goes over the wire and is never logged or printed as text: it appears only inside the QR code.
- Pairing (agreed): the QR code encodes `claudeboard://relay?v=1&h=<tailscale address>&p=<port>&s=<base64url secret>`. The iPhone app scans it once with an AVFoundation QR scanner and refuses any `h` that is not a Tailscale address. It stores host, port and secret in the iOS Keychain (`kSecClassGenericPassword`, service `dev.cicca.esptranslator.relay`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never in UserDefaults.
- Transport (agreed): a WebSocket (`NWProtocolWebSocket`, binary messages only, `maximumMessageSize = RelayFrame.maxFrame` = 2048) at `ws://<host>:<port>/relay`. WireGuard (Tailscale) encrypts it. The board message bytes carried inside are exactly the direct link's: a `toBoard` frame carries one `BoardMessage.encode()` result (`[kind][id u32 LE][text ≤ 400]`), which the iPhone chunks with the same `[flags][payload]` framing as the Mac (`BLEFraming.chunks`). A `fromBoard` frame carries one answer-characteristic notification exactly as the board sent it.
- Handshake (agreed): mutual HMAC-SHA256 challenge-response with the secret, and no secret on the wire. The Mac sends `challenge [version 1][nonceS 32]`. The iPhone answers `auth [nonceC 32][HMAC(secret, "cbrelay1 client" ‖ nonceS ‖ nonceC)]`. The Mac answers `welcome [HMAC(secret, "cbrelay1 server" ‖ nonceS ‖ nonceC)]`. Nonces are fresh 32 random bytes per connection, which makes it replay-protected. Proofs are compared in constant time (`HMAC.isValidAuthenticationCode`). The handshake has 10 s to finish. Any other frame before the handshake completes closes the connection. After 5 failed handshakes within 60 s the server refuses every new connection for 60 s. Only one relay is active: a newly authenticated relay replaces the old one.
- Relay role (agreed): the iPhone relays opaque frames and never interprets or answers a Claude message. Its only own words are its link hello (`BoardHello.relay`), its board-link and voice-status frames, and the transcripts of the board's voice audio. It subscribes to the board's Claude answer characteristic only while its WebSocket is authenticated, and unsubscribes when the WebSocket goes away.
- Board path selection (agreed): a connection gets a Claude role only from its explicit hello, written to the request characteristic after it subscribed to the answer characteristic. "mac" is refused on the connection that holds the translator audio role. "relay" is accepted only on that connection. Each role is held by at most one connection. The active Claude link is the Mac if one holds the Mac role, otherwise the relay. A restored (bonded) CCCD without a hello gives no role. Request writes are accepted only from answer-subscribed connections. Only the hello is acted on from a connection that is not active; anything else it writes is dropped. Inputs and voice audio go only to the active link.
- Daemon path selection (agreed): the active path is direct BLE when it is ready, otherwise the relay when its board link is up. An input that arrives over a ready relay while direct is active means the board has moved on: the relay becomes active until the direct link reconnects or sends an input. Every change of active path is reported as a disconnect followed by a connect (`RequestQueue.boardDisconnected`, `VoiceHub.boardDisconnected`, a hub resync, a time sync). A request pending at that moment falls through to the terminal, as on any disconnect today. It is never auto-answered.
- Voice away from the Mac (agreed): the board streams its voice ADPCM to the iPhone on the existing voice characteristic (the iPhone subscribes to it while its speech is ready). The iPhone buffers it from the capture's first packet (`seq` 0), transcribes on device (`DictationTranscriber`, `vi-VN`, the same model the translator already installed), and sends only text frames (`transcript`) to the Mac. No audio crosses the WebSocket. The Mac's `VoiceHub` is unchanged in behaviour: it cleans the final text (`VoiceText.forTyping`), shows it, and types or answers only after an explicit Send for that voice id, exactly as in Phase 3.
- Safety (spec): nothing is auto-approved. Request ids, voice ids, shapes and every Phase 2/3 check apply unchanged on both paths. The relay cannot invent an answer that the board did not send: it can only forward board notifications, and `RequestQueue.handle` accepts only the shown request's id and shape.
- Battery (agreed): no polling anywhere. The iPhone opens the WebSocket only while it is paired and the board's Claude service is connected. The keepalive is a WebSocket ping every 60 s from the iPhone (`RelayClient.pingInterval`, ≥ 30 s), plus TCP keepalive on the server (idle 60 s, interval 15 s, 4 probes). Relay traffic exists only for session events, requests, board inputs and voice captures. Reconnects use backoff (5 s doubling to 5 min) and also retry once at each network path change. Partial transcripts are sent at most every 250 ms.
- Tailscale is the user's job: the plan installs no software (no Tailscale, no `qrencode`, no Homebrew packages). QR rendering uses CoreImage. The README documents setup.
- Board UI text is English and uses only `font_vi_22` / `font_vi_36`. LVGL threading rules from Phase 1 apply unchanged (`*_locked` functions expect the display lock; never take it inside LVGL callbacks). The NimBLE host task stack stays 6144 with static buffers in access callbacks.
- iOS: deployment target stays iOS 26.0, and `SWIFT_VERSION` stays 5.0 for the app target (the package uses Swift 6 tools). `ios/project.yml` is the source of truth. Regenerate `ios/ESPTranslator.xcodeproj` with `xcodegen generate` and commit the regenerated `project.pbxproj`. Free developer accounts need the app reinstalled every 7 days (documented, unchanged).
- Commands (each finishes in under ~4 minutes):
  - shared package: `cd relay && swift build 2>&1 | grep -E "warning|error" ; swift test`
  - Mac: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test`
  - installer helpers: `cd mac && python3 -m unittest test_claude_settings test_cb -v`
  - host C tests: `cd firmware/test && cc -Wall -Wextra -Werror -I../main -o /tmp/<name> <name>.c ../main/<module>.c && /tmp/<name>`
  - firmware: `. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && cd firmware && idf.py build` (flash: `idf.py -p /dev/cu.usbmodem1101 flash monitor`)
  - iOS: `cd ios && xcodegen generate && xcodebuild -project ESPTranslator.xcodeproj -scheme ESPTranslator -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error|warning: unre|BUILD" | tail -20`
- Git: another agent may be committing at the same time. Stage exact paths only (never `git add -A` / `git add .`). If git reports `index.lock`, wait a few seconds and retry.
- Every commit message ends with exactly these two lines (after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
  ```

## Review Focus

1. **Someone else on the tailnet, or a replayed session.** Expected behaviour: a wrong secret, a recorded `auth` replayed against a new challenge, frames sent before `welcome`, a Mac-direction frame sent by the "phone", an oversized message, a text WebSocket message, or a remote address outside Tailscale gets the connection closed. Nothing reaches the router or the board, and repeated failures lock the port for 60 s. A fake Mac (wrong `welcome`) is refused by the iPhone. Pinned by Task 1 tests `replayedAuthIsRejected`, `fakeMacIsRejected`, `framesAreDirectionChecked`, and Task 3 tests `wrongSecretNeverReachesTheRelay`, `framesBeforeAuthCloseTheConnection`, `macFramesFromThePhoneCloseTheConnection`, `lockoutAfterRepeatedFailures`, `remotePolicyRefuses`.
2. **The daemon must never listen beyond Tailscale.** Expected behaviour: with no Tailscale interface, or a 100.x address on a non-`utun` interface (a carrier CGNAT), the daemon does not listen. A listener bound to one address cannot be reached through another. An address change rebinds. Pinned by Task 2 tests `onlyUtunTailscaleAddressesArePicked`, `cgnatOnEthernetIsNotTailscale`; Task 3 test `bindsOnlyTheGivenAddress`; Task 5 tests `watcherReportsOnlyChanges`, `addressGoneStopsTheListener`.
3. **The board switches links in the middle of things.** Cases: the Mac walks out of range while a request is shown, the board reports its mode over the relay before the daemon notices the BLE loss, or the Mac comes back. Expected behaviour: both sides end on the same path. The pending request falls through to the terminal (never auto-answered). Session rows resync on the new path. A capture in progress is cancelled. Pinned by Task 4 tests `relayInputWhileDirectMeansTheBoardMovedOn`, `directReturnTakesOver`, `inputFromAPathThatIsNotReadyIsDropped`; Task 6 tests `mac_preferred_over_relay`, `link_events_for_a_switch_with_voice`.
4. **An iPhone connection that is not a relay.** Cases: iOS reconnects for ANCS without the app, a bonded CCCD is restored, the app runs without a paired Mac, or a second Mac or relay says hello. Expected behaviour: none of these becomes a Claude link, and request writes from them are refused. Pinned by Task 6 tests `restored_subscription_without_hello_is_nothing`, `relay_only_on_the_phone_link`, `mac_never_on_the_phone_link`, `second_role_holder_is_refused`; Task 8 test `noBoardSubscriptionWithoutTheMac`.
5. **Voice timing over the relay.** Cases: audio arrives before the Mac's `voiceBegin`, the board starts a new capture before the old one was cancelled, the Mac never gets a final (iPhone killed mid-capture), or a transcript arrives for an old session. Expected behaviour: the transcript covers exactly the current capture's audio. A missing final ends as an empty transcript ("Didn't catch that"), and stale transcripts are ignored. Nothing is typed without Send. Pinned by Task 4 tests `finishTimesOutToEmpty`, `staleTranscriptsAreIgnored`, `relayGoneEndsTheStream`; Task 8 tests `earlyAudioIsFedAtBegin`, `aNewCaptureStopsFeedingTheOldSession`.

---

## File structure

```
relay/                                    NEW  shared Swift package "ClaudeRelay" (macOS 14, iOS 26)
  Package.swift
  Sources/ClaudeRelay/
    BLEFraming.swift      chunks (moved from BoardMessage.chunks), BoardHello.mac / .relay
    RelayFrame.swift      frame codec, direction checks, limits
    RelayAuth.swift       RelaySecret, proofs, ServerHandshake, ClientHandshake
    TailscaleAddress.swift  address rules, interface scan, pick
    RelayPairing.swift    QR payload (claudeboard://relay?...)
    RelayServer.swift     NWListener WebSocket server (one authenticated relay)
    RelayClient.swift     NWConnection WebSocket client (iPhone)
    WebSocketIO.swift     shared send/receive helpers for binary WebSocket messages
    RelayBridge.swift     iPhone relay state machine (pure) + VoiceAudioBuffer
  Tests/ClaudeRelayTests/
    FramingTests.swift  RelayFrameTests.swift  RelayAuthTests.swift  TailscalePairingTests.swift
    RelaySocketTests.swift  RelayBridgeTests.swift

mac/
  Package.swift                           MOD  depends on ../relay
  Sources/ClaudeBoardCore/
    BoardMessage.swift                    MOD  chunks forwards to BLEFraming
    RelaySetup.swift                      NEW  RelayConfig, RelaySecretFile, PairingQR
    BoardRouter.swift                     NEW  BoardPath, BoardRouter (BoardLinking)
    RelayVoice.swift                      NEW  RelayVoiceEngine, RoutedVoiceEngine
    RelayLink.swift                       NEW  RelayLink (server frames ↔ router/voice), RelayAddressWatcher
    VoiceHub.swift                        MOD  prepare() on every capture (relay readiness changes)
  Sources/claude-board/
    BoardLink.swift                       MOD  writes BoardHello.mac before reporting ready
    Pairing.swift                         NEW  claude-board --pair [--new-secret]
    main.swift                            MOD  router, relay server, routed voice engine
  install.sh / uninstall.sh               MOD  --pair (CLAUDE_BOARD_SKIP_PAIR=1 in tests) / remove the secret
  Tests/ClaudeBoardCoreTests/
    RelaySetupTests.swift  BoardRouterTests.swift  RelayVoiceTests.swift  RelayLinkTests.swift  NEW

firmware/main/
  claude_proto.h / .c                     MOD  kind 9 link hello (claude_parse_hello)
  claude_link.h / claude_link.c           NEW  pure role / path model
  ble_link.c                              MOD  roles per connection, per-link rx buffers, active-link routing
  claude_ui.c                             MOD  "Claude · via iPhone"
  app.h                                   MOD  ble_link_claude_relayed
  CMakeLists.txt                          MOD  claude_link.c
firmware/test/
  test_claude_link.c                      NEW
  test_claude_proto.c                     MOD  hello vectors
  claude_ble_test.py, claude_ble_phase2.py, claude_ble_voice.py   MOD  send the "mac" hello
  claude_ble_relay.py                     NEW  fake relay (bleak) for the on-device check

ios/
  project.yml                             MOD  ClaudeRelay package, camera + local network usage texts
  ESPTranslator.xcodeproj/project.pbxproj REGENERATED
  Sources/BLE/ESPLink.swift               MOD  Claude service (request / answer / voice)
  Sources/Relay/RelayKeychain.swift       NEW
  Sources/Relay/BoardVoiceTranscriber.swift NEW  on-device vi-VN dictation of the board audio
  Sources/Relay/ClaudeRelayService.swift  NEW  client + bridge + BLE + transcriber, reconnect policy
  Sources/UI/RelayView.swift              NEW  pairing (QR scanner), status, Forget
  Sources/UI/ContentView.swift            MOD  toolbar entry
  Sources/App/ConversationEngine.swift    MOD  `link` visible to the relay service
  Sources/App/ESPTranslatorApp.swift      MOD  creates the relay service

README.md                                 MOD  "Away from the Mac (iPhone relay)", relay protocol, setup
```

## Protocol (every side implements exactly this)

**Link hello (Mac or iPhone → board, request characteristic `…0011`, same `[flags][payload]` chunking):** message kind 9, id 0, text `mac` or `relay`. Sent once right after the answer subscription is confirmed. `BoardHello.mac` = `09 00 00 00 00 6d 61 63`, `BoardHello.relay` = `09 00 00 00 00 72 65 6c 61 79`. The board ignores kind 9 everywhere except in the link logic. Pre-Phase-5 firmware logs it as an unknown kind.

**Relay frames (WebSocket binary messages, first byte = type, integers little-endian):**

| type | name | sender | body | limits |
|---|---|---|---|---|
| 0x01 | toBoard | Mac | one encoded board message | 5…405 bytes |
| 0x02 | fromBoard | phone | one answer notification | 5…10 bytes |
| 0x03 | boardLink | phone | `[up u8]` (0/1): the iPhone holds the board's relay role | exactly 1 |
| 0x04 | voiceStatus | phone | `[0]` ready, or `[1][UTF-8 reason]` | reason 1…200 bytes |
| 0x10 | voiceBegin | Mac | `[session u32]` | session ≠ 0 |
| 0x11 | voiceFinish | Mac | `[session u32]` | session ≠ 0 |
| 0x12 | voiceCancel | Mac | `[session u32]` | session ≠ 0 |
| 0x13 | transcript | phone | `[session u32][final u8][UTF-8 text]` | text ≤ 1000 bytes |
| 0x14 | voiceFailed | phone | `[session u32][UTF-8 reason]` | reason 1…200 bytes |
| 0x20 | challenge | Mac | `[version u8 = 1][nonceS 32]` | exactly 33 |
| 0x21 | auth | phone | `[nonceC 32][proof 32]` | exactly 64 |
| 0x22 | welcome | Mac | `[proof 32]` | exactly 32 |

Any frame that is malformed, of unknown type, or from the wrong sender closes the connection. Text must be valid UTF-8.

Shared test vectors (asserted in Swift and, for the hello, in C):
- secret `00 01 … 1f` (bytes 0…31) is `AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8` in base64url. With nonceS = 32 × `11` and nonceC = 32 × `22`: client proof `332a196afabe6ab2b492ba08f835602b52e2c327016a00b083aff37647bfc636`, server proof `3e25f1bef14172ec012a9220275b5b255f5e66a4f5ed02b4e3cf7431f745529f`.
- `toBoard(02 09 00 00 00)` → `01 02 09 00 00 00`; `transcript(7, final, "Xin chào")` → `13 07 00 00 00 01` + UTF-8 "Xin chào"; `boardLink(true)` → `03 01`; `voiceStatus(ready)` → `04 00`; `voiceBegin(5)` → `10 05 00 00 00`.
- Pairing URL for host `100.101.102.103`, port 47821 and that secret: `claudeboard://relay?v=1&h=100.101.102.103&p=47821&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8`.

---
## Task order and dependencies

1 → 2 → 3 (shared package, then the Mac pieces that use it) → 4 → 5 (daemon) → 6 → 7 (firmware; after Phase 4 is merged; Task 7 installs the Task 5 daemon because the new firmware needs the "mac" hello) → 8 → 9 (iPhone) → 10 (README + hardware). Tasks 6 and 8 depend only on Task 1 and could run in parallel with 4–5, but run them in order: every task commits on the same branch.

---

### Task 1: Shared package `ClaudeRelay`: BLE framing, link hello, relay frames and the handshake (pure)

**Files:**
- Create: `relay/Package.swift`, `relay/Sources/ClaudeRelay/BLEFraming.swift`, `relay/Sources/ClaudeRelay/RelayFrame.swift`, `relay/Sources/ClaudeRelay/RelayAuth.swift`
- Create (tests): `relay/Tests/ClaudeRelayTests/FramingTests.swift`, `relay/Tests/ClaudeRelayTests/RelayFrameTests.swift`, `relay/Tests/ClaudeRelayTests/RelayAuthTests.swift`
- Modify: `mac/Package.swift` (dependency on `../relay`), `mac/Sources/ClaudeBoardCore/BoardMessage.swift` (`chunks` forwards to `BLEFraming.chunks`)

**Interfaces:**
- Consumes: nothing (first task). `BoardMessage.chunks(_:maxChunk:)` keeps its signature (its tests in `CoreTests.swift` stay green).
- Produces (used by every later task):
  - `public enum BLEFraming { public static func chunks(_ data: Data, maxChunk: Int) -> [Data] }`
  - `public enum BoardHello { public static let kind: UInt8; public static let mac: Data; public static let relay: Data }`
  - `public enum RelayFrame: Equatable, Sendable`: cases `toBoard(Data)`, `fromBoard(Data)`, `boardLink(Bool)`, `voiceStatus(String?)`, `voiceBegin(UInt32)`, `voiceFinish(UInt32)`, `voiceCancel(UInt32)`, `transcript(UInt32, final: Bool, String)`, `voiceFailed(UInt32, String)`, `challenge(Data)`, `auth(nonce: Data, proof: Data)`, `welcome(Data)`. Also `enum Sender { mac, phone }`, `var sender`, `func encode() -> Data`, `static func decode(_ data: Data, from: Sender) -> RelayFrame?`, `static func fit(_ s: String, maxBytes: Int) -> String`, and the constants `version` (1), `maxBoardMessage` (405), `maxBoardInput` (10), `maxText` (1000), `maxReason` (200), `maxFrame` (2048).
  - `public struct RelaySecret: Equatable, Sendable { init?(_ bytes: Data); init?(base64url: String); var bytes: Data; var base64url: String; static func random() -> RelaySecret }`
  - `public enum RelayAuth { static let nonceSize = 32; static func randomBytes(_ n: Int) -> Data; static func clientProof(_:server:client:) -> Data; static func serverProof(_:server:client:) -> Data }`
  - `public struct ServerHandshake: Sendable { init(secret:nonce:); var challenge: RelayFrame; mutating func receive(_ frame: RelayFrame) -> Outcome }` with `enum Outcome: Equatable { case accepted(welcome: RelayFrame), rejected }`
  - `public struct ClientHandshake: Sendable { init(secret:nonce:); mutating func receive(_ frame: RelayFrame) -> Step }` with `enum Step: Equatable { case send(RelayFrame), authenticated, rejected }`

- [ ] **Step 1: Create the package manifest**

`relay/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// Shared by the Mac daemon (mac/Package.swift) and the iPhone app (ios/project.yml): everything both ends of the
// iPhone relay must agree on. Tested on the Mac with `swift test`, without Tailscale (loopback only).
let package = Package(
    name: "ClaudeRelay",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [.library(name: "ClaudeRelay", targets: ["ClaudeRelay"])],
    targets: [
        .target(name: "ClaudeRelay"),
        .testTarget(name: "ClaudeRelayTests", dependencies: ["ClaudeRelay"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`relay/Tests/ClaudeRelayTests/FramingTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeRelay

@Test func chunksCarryFirstAndLastFlags() {
    let data = Data((0..<25).map { UInt8($0) })
    let c = BLEFraming.chunks(data, maxChunk: 11)          // 10 payload bytes per chunk
    #expect(c.count == 3)
    #expect(c.map { $0.first! } == [0x01, 0x00, 0x02])
    #expect(c.reduce(Data()) { $0 + $1.dropFirst() } == data)
    #expect(BLEFraming.chunks(Data([1]), maxChunk: 20) == [Data([0x03, 1])])
}

@Test func helloVectors() {
    #expect(BoardHello.mac == Data([0x09, 0, 0, 0, 0, 0x6d, 0x61, 0x63]))
    #expect(BoardHello.relay == Data([0x09, 0, 0, 0, 0, 0x72, 0x65, 0x6c, 0x61, 0x79]))
    #expect(BoardHello.kind == 9)
}
```

`relay/Tests/ClaudeRelayTests/RelayFrameTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeRelay

@Test func frameVectors() {
    #expect(RelayFrame.toBoard(Data([2, 9, 0, 0, 0])).encode() == Data([0x01, 2, 9, 0, 0, 0]))
    #expect(RelayFrame.transcript(7, final: true, "Xin chào").encode() == Data([0x13, 7, 0, 0, 0, 1]) + Data("Xin chào".utf8))
    #expect(RelayFrame.boardLink(true).encode() == Data([0x03, 1]))
    #expect(RelayFrame.voiceStatus(nil).encode() == Data([0x04, 0]))
    #expect(RelayFrame.voiceStatus("No model").encode() == Data([0x04, 1]) + Data("No model".utf8))
    #expect(RelayFrame.voiceBegin(5).encode() == Data([0x10, 5, 0, 0, 0]))
}

@Test func everyFrameRoundTripsFromItsSender() {
    let frames: [RelayFrame] = [
        .toBoard(Data([0, 1, 0, 0, 0]) + Data("p\nBash\nls".utf8)), .fromBoard(Data([4, 3, 2, 1, 1])),
        .boardLink(false), .boardLink(true), .voiceStatus(nil), .voiceStatus("Allow Speech Recognition"),
        .voiceBegin(1), .voiceFinish(0xffff_ffff), .voiceCancel(9),
        .transcript(3, final: false, "đang nói"), .transcript(3, final: true, ""), .voiceFailed(3, "no model"),
        .challenge(Data([1]) + Data(repeating: 0x11, count: 32)),
        .auth(nonce: Data(repeating: 0x22, count: 32), proof: Data(repeating: 0x33, count: 32)),
        .welcome(Data(repeating: 0x44, count: 32)),
    ]
    for f in frames {
        #expect(RelayFrame.decode(f.encode(), from: f.sender) == f, "\(f)")
    }
}

@Test func framesAreDirectionChecked() {
    // A Mac frame claimed by the phone (and the reverse) is refused
    #expect(RelayFrame.decode(RelayFrame.toBoard(Data([2, 9, 0, 0, 0])).encode(), from: .phone) == nil)
    #expect(RelayFrame.decode(RelayFrame.fromBoard(Data([9, 0, 0, 0, 0x32])).encode(), from: .mac) == nil)
    #expect(RelayFrame.decode(RelayFrame.voiceBegin(5).encode(), from: .phone) == nil)
    #expect(RelayFrame.decode(RelayFrame.welcome(Data(count: 32)).encode(), from: .phone) == nil)
}

@Test func malformedFramesAreRefused() {
    let bad: [(Data, RelayFrame.Sender)] = [
        (Data(), .mac),
        (Data([0x01, 2, 9, 0, 0]), .mac),                                        // board message shorter than 5
        (Data([0x01]) + Data(count: 406), .mac),                                 // longer than 405
        (Data([0x02, 1, 2, 3, 4]), .phone),                                      // input shorter than 5
        (Data([0x02]) + Data(count: 11), .phone),                                // input longer than 10
        (Data([0x03, 2]), .phone), (Data([0x03]), .phone), (Data([0x03, 1, 1]), .phone),
        (Data([0x04, 1]), .phone),                                               // a reason flag without a reason
        (Data([0x04, 0, 0x41]), .phone),                                         // ready with trailing bytes
        (Data([0x10, 0, 0, 0, 0]), .mac),                                        // session 0
        (Data([0x11, 1, 0, 0]), .mac),                                           // short session
        (Data([0x13, 1, 0, 0, 0, 2]), .phone),                                   // final flag 2
        (Data([0x13, 1, 0, 0, 0, 1, 0xff, 0xfe]), .phone),                       // invalid UTF-8
        (Data([0x13, 1, 0, 0, 0, 1]) + Data(repeating: 0x41, count: 1001), .phone),
        (Data([0x14, 1, 0, 0, 0]), .phone),                                      // empty reason
        (Data([0x20, 2]) + Data(count: 32), .mac),                               // unknown version
        (Data([0x20, 1]) + Data(count: 31), .mac),
        (Data([0x21]) + Data(count: 63), .phone),
        (Data([0x22]) + Data(count: 33), .mac),
        (Data([0x7f, 0]), .mac),                                                 // unknown type
        (Data([0x01]) + Data(count: 2048), .mac),                                // over maxFrame
    ]
    for (d, s) in bad { #expect(RelayFrame.decode(d, from: s) == nil, "\([UInt8](d.prefix(8)))") }
}

@Test func fitCutsAtCharacterBoundaries() {
    #expect(RelayFrame.fit("chào", maxBytes: 4) == "chà")    // c h à(2 bytes) = 4
    #expect(RelayFrame.fit("chào", maxBytes: 3) == "ch")     // "à" never split
    #expect(RelayFrame.fit("abc", maxBytes: 10) == "abc")
    #expect(RelayFrame.fit("", maxBytes: 0) == "")
}
```

`relay/Tests/ClaudeRelayTests/RelayAuthTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd relay && swift test 2>&1 | tail -5`
Expected: build errors (`cannot find 'BLEFraming' in scope`, …).

- [ ] **Step 4: Implement**

`relay/Sources/ClaudeRelay/BLEFraming.swift`:

```swift
import Foundation

/// The board's request characteristic takes one message as BLE writes [flags u8][payload], flags bit0 = first,
/// bit1 = last. The Mac (direct) and the iPhone (relay) both chunk with this, to their link's write size.
public enum BLEFraming {
    public static func chunks(_ data: Data, maxChunk: Int) -> [Data] {
        let size = max(1, maxChunk - 1)
        var out: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }
            if end == data.count { flags |= 0x02 }
            out.append(Data([flags]) + data[data.startIndex + offset ..< data.startIndex + end])
            offset = end
        } while offset < data.count
        return out
    }
}

/// Link hello (message kind 9, id 0), written once after the answer subscription is confirmed. The board gives a
/// connection a Claude role only from this: "mac" (the daemon, direct BLE) or "relay" (the iPhone app).
public enum BoardHello {
    public static let kind: UInt8 = 9
    public static let mac = Data([kind, 0, 0, 0, 0]) + Data("mac".utf8)
    public static let relay = Data([kind, 0, 0, 0, 0]) + Data("relay".utf8)
}
```

`relay/Sources/ClaudeRelay/RelayFrame.swift`:

```swift
import Foundation

/// One WebSocket binary message between the Mac daemon and the iPhone relay. The board's own bytes travel
/// unchanged inside toBoard / fromBoard; everything else is the relay's own small vocabulary (README, "Relay
/// protocol"). Integers are little-endian.
public enum RelayFrame: Equatable, Sendable {
    /// Mac → phone: one encoded board message ([kind][id u32][text]); the phone chunks it to the board
    case toBoard(Data)
    /// Phone → Mac: one answer-characteristic notification, exactly as the board sent it
    case fromBoard(Data)
    /// Phone → Mac: the phone holds (or lost) the board's relay role
    case boardLink(Bool)
    /// Phone → Mac: nil = the phone can transcribe board voice; else why not (shown on the board)
    case voiceStatus(String?)
    /// Mac → phone: transcribe the board's current capture as session n / end it and send the final / drop it
    case voiceBegin(UInt32)
    case voiceFinish(UInt32)
    case voiceCancel(UInt32)
    /// Phone → Mac: transcript of session n (partial, or the final one after voiceFinish)
    case transcript(UInt32, final: Bool, String)
    /// Phone → Mac: session n could not be transcribed
    case voiceFailed(UInt32, String)
    /// Handshake: Mac challenge [version][nonceS 32], phone auth [nonceC 32][proof 32], Mac welcome [proof 32]
    case challenge(Data)
    case auth(nonce: Data, proof: Data)
    case welcome(Data)

    public enum Sender: Equatable, Sendable { case mac, phone }

    public static let version: UInt8 = 1
    /// 5-byte header + the board's CLAUDE_TEXT_MAX (400)
    public static let maxBoardMessage = 405
    /// The board's CLAUDE_INPUT_MAX
    public static let maxBoardInput = 10
    public static let maxText = 1000
    public static let maxReason = 200
    public static let maxFrame = 2048

    public var sender: Sender {
        switch self {
        case .toBoard, .voiceBegin, .voiceFinish, .voiceCancel, .challenge, .welcome: .mac
        case .fromBoard, .boardLink, .voiceStatus, .transcript, .voiceFailed, .auth: .phone
        }
    }

    public func encode() -> Data {
        switch self {
        case .toBoard(let d): return Data([0x01]) + d
        case .fromBoard(let d): return Data([0x02]) + d
        case .boardLink(let up): return Data([0x03, up ? 1 : 0])
        case .voiceStatus(let why): return why.map { Data([0x04, 1]) + Data($0.utf8) } ?? Data([0x04, 0])
        case .voiceBegin(let s): return Data([0x10]) + Self.le32(s)
        case .voiceFinish(let s): return Data([0x11]) + Self.le32(s)
        case .voiceCancel(let s): return Data([0x12]) + Self.le32(s)
        case .transcript(let s, let final, let text): return Data([0x13]) + Self.le32(s) + Data([final ? 1 : 0]) + Data(text.utf8)
        case .voiceFailed(let s, let why): return Data([0x14]) + Self.le32(s) + Data(why.utf8)
        case .challenge(let body): return Data([0x20]) + body
        case .auth(let nonce, let proof): return Data([0x21]) + nonce + proof
        case .welcome(let proof): return Data([0x22]) + proof
        }
    }

    /// nil: malformed, unknown, or not a frame `sender` may send (the connection is then closed)
    public static func decode(_ data: Data, from sender: Sender) -> RelayFrame? {
        let all = [UInt8](data)
        guard let type = all.first, all.count <= maxFrame else { return nil }
        let b = Array(all.dropFirst())
        let frame: RelayFrame?
        switch type {
        case 0x01: frame = (5...maxBoardMessage).contains(b.count) ? .toBoard(Data(b)) : nil
        case 0x02: frame = (5...maxBoardInput).contains(b.count) ? .fromBoard(Data(b)) : nil
        case 0x03: frame = b.count == 1 && b[0] <= 1 ? .boardLink(b[0] == 1) : nil
        case 0x04:
            if b == [0] { frame = .voiceStatus(nil) }
            else if b.first == 1, let why = text(b.dropFirst(), 1...maxReason) { frame = .voiceStatus(why) }
            else { frame = nil }
        case 0x10, 0x11, 0x12:
            guard b.count == 4, let s = session(b) else { return nil }
            frame = type == 0x10 ? .voiceBegin(s) : type == 0x11 ? .voiceFinish(s) : .voiceCancel(s)
        case 0x13:
            guard b.count >= 5, let s = session(b), b[4] <= 1, let t = text(b.dropFirst(5), 0...maxText) else { return nil }
            frame = .transcript(s, final: b[4] == 1, t)
        case 0x14:
            guard b.count >= 4, let s = session(b), let why = text(b.dropFirst(4), 1...maxReason) else { return nil }
            frame = .voiceFailed(s, why)
        case 0x20: frame = b.count == 33 && b[0] == version ? .challenge(Data(b)) : nil
        case 0x21: frame = b.count == 64 ? .auth(nonce: Data(b[0..<32]), proof: Data(b[32..<64])) : nil
        case 0x22: frame = b.count == 32 ? .welcome(Data(b)) : nil
        default: frame = nil
        }
        guard let frame, frame.sender == sender else { return nil }
        return frame
    }

    /// The longest prefix of `s` within `maxBytes` UTF-8 bytes, cut at a Character boundary
    public static func fit(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]) }

    private static func session(_ b: [UInt8]) -> UInt32? {
        let s = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return s == 0 ? nil : s
    }

    private static func text(_ bytes: ArraySlice<UInt8>, _ range: ClosedRange<Int>) -> String? {
        guard range.contains(bytes.count) else { return nil }
        return String(bytes: Array(bytes), encoding: .utf8)
    }
}
```

`relay/Sources/ClaudeRelay/RelayAuth.swift`:

```swift
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
```

- [ ] **Step 5: Run the shared tests**

Run: `cd relay && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -5`
Expected: no warnings; all tests pass.

- [ ] **Step 6: Point the Mac package at the shared one and forward `chunks`**

In `mac/Package.swift`, add `dependencies: [.package(path: "../relay")],` after `platforms:`, and add the product to the three targets that need it:

```swift
        .target(name: "ClaudeBoardCore", dependencies: [.product(name: "ClaudeRelay", package: "relay")]),
        .executableTarget(name: "claude-board-hook", dependencies: ["ClaudeBoardCore"]),
        .executableTarget(
            name: "claude-board",
            dependencies: ["ClaudeBoardCore", .product(name: "ClaudeRelay", package: "relay")],
            // exclude / linkerSettings unchanged
        ),
        .testTarget(name: "ClaudeBoardCoreTests",
                    dependencies: ["ClaudeBoardCore", .product(name: "ClaudeRelay", package: "relay")]),
```

In `mac/Sources/ClaudeBoardCore/BoardMessage.swift`, add `import ClaudeRelay` and replace the body of `chunks` with the forwarder (the doc comment stays):

```swift
    public static func chunks(_ data: Data, maxChunk: Int) -> [Data] {
        BLEFraming.chunks(data, maxChunk: maxChunk)
    }
```

- [ ] **Step 7: Run the Mac tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings; all tests pass (the chunk tests in `CoreTests.swift` now exercise `BLEFraming`).

- [ ] **Step 8: Commit**

```bash
git add relay/Package.swift relay/Sources/ClaudeRelay/BLEFraming.swift relay/Sources/ClaudeRelay/RelayFrame.swift \
        relay/Sources/ClaudeRelay/RelayAuth.swift relay/Tests/ClaudeRelayTests/FramingTests.swift \
        relay/Tests/ClaudeRelayTests/RelayFrameTests.swift relay/Tests/ClaudeRelayTests/RelayAuthTests.swift \
        mac/Package.swift mac/Sources/ClaudeBoardCore/BoardMessage.swift
git commit -m "relay: shared ClaudeRelay package (BLE framing, link hello, relay frames, HMAC handshake)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

(If `mac/Package.resolved` appears, stage it too. A path dependency normally adds nothing.)

---

### Task 2: Tailscale address rules, the pairing code, the secret file and `claude-board --pair`

**Files:**
- Create: `relay/Sources/ClaudeRelay/TailscaleAddress.swift`, `relay/Sources/ClaudeRelay/RelayPairing.swift`, `relay/Tests/ClaudeRelayTests/TailscalePairingTests.swift`
- Create: `mac/Sources/ClaudeBoardCore/RelaySetup.swift`, `mac/Tests/ClaudeBoardCoreTests/RelaySetupTests.swift`, `mac/Sources/claude-board/Pairing.swift`
- Modify: `mac/Sources/claude-board/main.swift` (the `--pair` early exit, next to `--transcribe`), `mac/install.sh`, `mac/uninstall.sh`

**Interfaces:**
- Consumes: `RelaySecret` (Task 1).
- Produces:
  - `public enum TailscaleAddress { struct Interface { name, address; init(name:address:) }; static func isTailscale(_ ip: String) -> Bool; static func pick(_ interfaces: [Interface]) -> String?; static func interfaces() -> [Interface] }`
  - `public struct RelayPairing: Equatable, Sendable { host: String; port: UInt16; secret: RelaySecret; init(host:port:secret:); var url: String; var webSocketURL: URL; static func parse(_ text: String) -> RelayPairing? }`
  - Core: `public enum RelayConfig { static let port: UInt16 = 47821; static var directory: String; static var secretPath: String }`, `public enum RelaySecretError: Error, Equatable`, `public enum RelaySecretFile { static func load(path:) -> Result<RelaySecret, RelaySecretError>; static func loadOrCreate(path:rotate:) throws -> RelaySecret }`, `public enum PairingQR { static func matrix(_ text: String) -> [[Bool]]?; static func terminal(_ m: [[Bool]], quiet: Int = 2) -> String }`
  - CLI: `claude-board --pair [--new-secret]`. Exit 0 = printed. 2 = no Tailscale address (the secret is still created). 1 = error.

- [ ] **Step 1: Write the failing shared tests**

`relay/Tests/ClaudeRelayTests/TailscalePairingTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd relay && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'TailscaleAddress'`).

- [ ] **Step 3: Implement the shared parts**

`relay/Sources/ClaudeRelay/TailscaleAddress.swift`:

```swift
import Darwin
import Foundation

/// Where the relay may listen and connect: Tailscale's addresses only (100.64.0.0/10 and fd7a:115c:a1e0::/48 on a
/// utun interface). 100.64/10 alone is not enough: carriers use it too (CGNAT), so the interface must be a tunnel.
public enum TailscaleAddress {
    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public static func isTailscale(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) & 0xFFC0_0000 == 0x6440_0000   // 100.64.0.0/10
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0.prefix(6)) }
            return b == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]                  // fd7a:115c:a1e0::/48
        }
        return false
    }

    /// The address to listen on: a Tailscale address on a utun interface, IPv4 preferred; nil = do not listen
    public static func pick(_ interfaces: [Interface]) -> String? {
        let ok = interfaces.filter { $0.name.hasPrefix("utun") && isTailscale($0.address) }
        return (ok.first { !$0.address.contains(":") } ?? ok.first)?.address
    }

    /// Every IPv4 / IPv6 address of every interface (getifaddrs; no subprocess, works under launchd)
    public static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Interface] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            out.append(Interface(name: String(cString: p.pointee.ifa_name), address: address))
        }
        return out
    }
}
```

`relay/Sources/ClaudeRelay/RelayPairing.swift`:

```swift
import Foundation

/// What the iPhone needs to reach the daemon, as the QR code printed by `claude-board --pair` carries it:
/// claudeboard://relay?v=1&h=<tailscale address>&p=<port>&s=<base64url secret>
public struct RelayPairing: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let secret: RelaySecret

    public init(host: String, port: UInt16, secret: RelaySecret) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    public var url: String { "claudeboard://relay?v=1&h=\(host)&p=\(port)&s=\(secret.base64url)" }

    public var webSocketURL: URL {
        URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(port)/relay")!
    }

    /// nil unless it is exactly a version-1 pairing code for a Tailscale address
    public static func parse(_ text: String) -> RelayPairing? {
        guard let c = URLComponents(string: text), c.scheme == "claudeboard", c.host == "relay",
              let items = c.queryItems else { return nil }
        func one(_ name: String) -> String? {
            let v = items.filter { $0.name == name }
            return v.count == 1 ? v[0].value : nil
        }
        guard one("v") == "1", let host = one("h"), TailscaleAddress.isTailscale(host),
              let port = one("p").flatMap({ UInt16($0) }), port != 0,
              let secret = one("s").flatMap({ RelaySecret(base64url: $0) }) else { return nil }
        return RelayPairing(host: host, port: port, secret: secret)
    }
}
```

Run: `cd relay && swift test 2>&1 | tail -3`. Expected: all pass.

- [ ] **Step 4: Write the failing Mac tests**

`mac/Tests/ClaudeBoardCoreTests/RelaySetupTests.swift`:

```swift
import ClaudeRelay
import CoreImage
import Foundation
import Testing
@testable import ClaudeBoardCore

private func tempDir() -> String {
    let d = NSTemporaryDirectory() + "relay-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func mode(_ path: String) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
}

@Test func secretIsCreatedOwnerOnlyAndReloaded() throws {
    let path = tempDir() + "/sub/relay.secret"
    let s = try RelaySecretFile.loadOrCreate(path: path)
    #expect(mode(path) == 0o600)
    #expect(mode((path as NSString).deletingLastPathComponent) == 0o700)
    #expect(try RelaySecretFile.load(path: path).get() == s)
    #expect(try RelaySecretFile.loadOrCreate(path: path) == s)            // kept
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text == s.base64url + "\n")
}

@Test func rotateReplacesTheSecret() throws {
    let path = tempDir() + "/relay.secret"
    let a = try RelaySecretFile.loadOrCreate(path: path)
    let b = try RelaySecretFile.loadOrCreate(path: path, rotate: true)
    #expect(a != b)
    #expect(try RelaySecretFile.load(path: path).get() == b)
    #expect(mode(path) == 0o600)
}

@Test func unsafeSecretFilesAreRefused() throws {
    let dir = tempDir()
    let open = dir + "/open"
    _ = try RelaySecretFile.loadOrCreate(path: open)
    chmod(open, 0o644)
    #expect(RelaySecretFile.load(path: open) == .failure(.tooOpen(mode: 0o644)))
    #expect(throws: RelaySecretError.tooOpen(mode: 0o644)) { try RelaySecretFile.loadOrCreate(path: open) }  // never replaced silently

    let real = dir + "/real"
    _ = try RelaySecretFile.loadOrCreate(path: real)
    let link = dir + "/link"
    symlink(real, link)
    #expect(RelaySecretFile.load(path: link) == .failure(.notRegularFile))

    let junk = dir + "/junk"
    FileManager.default.createFile(atPath: junk, contents: Data("not a secret\n".utf8), attributes: [.posixPermissions: 0o600])
    #expect(RelaySecretFile.load(path: junk) == .failure(.malformed))
    #expect(RelaySecretFile.load(path: dir + "/missing") == .failure(.missing))
}

/// Renders a module matrix as a grey bitmap (quiet zone 4, 8 px per module) and decodes it with CoreImage
private func decode(_ m: [[Bool]]) -> String? {
    let scale = 8, quiet = 4, n = (m.count + 2 * quiet) * scale
    var px = [UInt8](repeating: 255, count: n * n)
    for (y, row) in m.enumerated() {
        for (x, dark) in row.enumerated() where dark {
            for dy in 0..<scale { for dx in 0..<scale { px[((y + quiet) * scale + dy) * n + (x + quiet) * scale + dx] = 0 } }
        }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
    return (detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString
}

@Test func pairingQRDecodesToTheURL() throws {
    let url = RelayPairing(host: "100.101.102.103", port: RelayConfig.port, secret: RelaySecret.random()).url
    let m = try #require(PairingQR.matrix(url))
    #expect(m.count == m.first?.count)
    #expect(decode(m) == url)
}

@Test func terminalQRUsesHalfBlocksOnWhite() throws {
    let m = try #require(PairingQR.matrix("claudeboard://relay?v=1"))
    let lines = PairingQR.terminal(m, quiet: 2).split(separator: "\n")
    #expect(lines.count == (m.count + 4 + 1) / 2)
    #expect(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
}
```

- [ ] **Step 5: Run them to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'RelaySecretFile'`).

- [ ] **Step 6: Implement `RelaySetup.swift`**

`mac/Sources/ClaudeBoardCore/RelaySetup.swift`:

```swift
import ClaudeRelay
import CoreImage
import Foundation

public enum RelayConfig {
    /// The daemon's WebSocket port on its Tailscale address
    public static let port: UInt16 = 47821
    /// ~/.claude-board (CLAUDE_BOARD_HOME overrides it, for trying --pair without touching the real install)
    public static var directory: String {
        ProcessInfo.processInfo.environment["CLAUDE_BOARD_HOME"] ?? NSHomeDirectory() + "/.claude-board"
    }
    public static var secretPath: String { directory + "/relay.secret" }
}

public enum RelaySecretError: Error, Equatable, CustomStringConvertible {
    case missing, notRegularFile, wrongOwner, tooOpen(mode: UInt16), unreadable, malformed

    public var description: String {
        switch self {
        case .missing: "no relay secret"
        case .notRegularFile: "the relay secret is not a regular file (symlink?)"
        case .wrongOwner: "the relay secret belongs to another user"
        case .tooOpen(let m): "the relay secret is readable by others (mode \(String(m, radix: 8)), must be 600)"
        case .unreadable: "the relay secret cannot be read or written"
        case .malformed: "the relay secret is malformed"
        }
    }
}

/// ~/.claude-board/relay.secret: base64url + "\n", mode 0600, owned by the user. Anything else is refused (the
/// relay then stays off) and never silently replaced; `claude-board --pair --new-secret` replaces it on purpose.
public enum RelaySecretFile {
    public static func load(path: String) -> Result<RelaySecret, RelaySecretError> {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(errno == ENOENT ? .missing : .unreadable) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard st.st_uid == getuid() else { return .failure(.wrongOwner) }
        guard st.st_mode & 0o077 == 0 else { return .failure(.tooOpen(mode: UInt16(st.st_mode & 0o777))) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .failure(.unreadable) }
        guard let secret = RelaySecret(base64url: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.malformed)
        }
        return .success(secret)
    }

    /// The existing secret, or a new one when there is none (or `rotate`). Written to a 0600 temp file
    /// (O_EXCL | O_NOFOLLOW) in the 0700 directory, then renamed over the old one.
    public static func loadOrCreate(path: String, rotate: Bool = false) throws -> RelaySecret {
        if !rotate {
            switch load(path: path) {
            case .success(let s): return s
            case .failure(.missing): break
            case .failure(let e): throw e
            }
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let secret = RelaySecret.random()
        let tmp = path + ".tmp.\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RelaySecretError.unreadable }
        let line = Data((secret.base64url + "\n").utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == line.count, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw RelaySecretError.unreadable
        }
        return secret
    }
}

/// The pairing QR code for the terminal (CoreImage: nothing to install).
public enum PairingQR {
    /// Dark modules, top row first, including CoreImage's own margin
    public static func matrix(_ text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var px = [UInt8](repeating: 255, count: w * h)
        CIContext().render(image, toBitmap: &px, rowBytes: w, bounds: image.extent, format: .L8,
                           colorSpace: CGColorSpaceCreateDeviceGray())
        return (0..<h).map { y in (0..<w).map { x in px[y * w + x] < 128 } }
    }

    /// Two module rows per text line with half blocks, black on white whatever the terminal's colours
    public static func terminal(_ m: [[Bool]], quiet: Int = 2) -> String {
        let size = m.count + 2 * quiet
        func dark(_ y: Int, _ x: Int) -> Bool {
            let (r, c) = (y - quiet, x - quiet)
            return r >= 0 && r < m.count && c >= 0 && c < m.count && m[r][c]
        }
        var lines: [String] = []
        for y in stride(from: 0, to: size, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in 0..<size {
                switch (dark(y, x), dark(y + 1, x)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }
}
```

`pairingQRDecodesToTheURL` may fail because `render(toBitmap:)` returns the rows bottom-up, which gives a mirrored code that cannot be decoded. In that case, build the rows with `(0..<h).reversed()` and note it in the doc comment. The test decides.

- [ ] **Step 7: Run the Mac tests**

Run: `cd mac && swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 8: The `--pair` command**

`mac/Sources/claude-board/Pairing.swift`:

```swift
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
```

In `mac/Sources/claude-board/main.swift`, right after the `--transcribe` block, add:

```swift
// Pairing for the iPhone relay: claude-board --pair [--new-secret] (no board, no socket)
if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--pair" {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    guard rest.isEmpty || rest == ["--new-secret"] else {
        print("usage: claude-board --pair [--new-secret]")
        exit(1)
    }
    exit(runPair(newSecret: rest == ["--new-secret"]))
}
```

- [ ] **Step 9: Installer and uninstaller**

In `mac/install.sh`, insert before the `if [ "${CLAUDE_BOARD_SKIP_LAUNCHD:-0}" != 1 ]; then` line (the daemon must start with the secret already in place), and add `CLAUDE_BOARD_SKIP_PAIR=1` to the "Test overrides" comment on line 3:

```bash
# iPhone relay: the pairing secret (0600) and the QR code the app scans once. Needs Tailscale (installed by you,
# see README "Away from the Mac"); never fatal.
if [ "${CLAUDE_BOARD_SKIP_PAIR:-0}" != 1 ]; then
  "$BIN/claude-board" --pair || echo "iPhone relay not set up (see README: Away from the Mac)."
fi
```

In `mac/uninstall.sh`, inside the `CLAUDE_BOARD_SKIP_LAUNCHD` block after the `rm -f …plist` line, add:

```bash
  rm -f "$HOME/.claude-board/relay.secret"   # the iPhone pairing stops working; pair again after reinstalling
```

- [ ] **Step 10: Verify**

Run:
```bash
cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3
bash -n install.sh && bash -n uninstall.sh
d=$(mktemp -d) && CLAUDE_BOARD_HOME="$d" .build/debug/claude-board --pair; echo "exit $?"; ls -l "$d"; rm -rf "$d"
python3 -m unittest test_claude_settings test_cb 2>&1 | tail -2
```
Expected: the tests pass. `--pair` prints the QR code and exits 0 when this Mac runs Tailscale, or prints the Tailscale instructions and exits 2. Either way the temp dir holds `relay.secret` with `-rw-------`. The throwaway secret is deleted with the temp dir. Never run `--pair` without `CLAUDE_BOARD_HOME` in this task: that would print the real pairing code into the session log.

- [ ] **Step 11: Commit**

```bash
git add relay/Sources/ClaudeRelay/TailscaleAddress.swift relay/Sources/ClaudeRelay/RelayPairing.swift \
        relay/Tests/ClaudeRelayTests/TailscalePairingTests.swift mac/Sources/ClaudeBoardCore/RelaySetup.swift \
        mac/Tests/ClaudeBoardCoreTests/RelaySetupTests.swift mac/Sources/claude-board/Pairing.swift \
        mac/Sources/claude-board/main.swift mac/install.sh mac/uninstall.sh
git commit -m "mac, relay: Tailscale address rules, pairing code, 0600 relay secret and claude-board --pair (QR)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---
### Task 3: The WebSocket server and client (Network.framework, loopback-tested)

**Files:**
- Create: `relay/Sources/ClaudeRelay/WebSocketIO.swift`, `relay/Sources/ClaudeRelay/RelayServer.swift`, `relay/Sources/ClaudeRelay/RelayClient.swift`
- Test: `relay/Tests/ClaudeRelayTests/RelaySocketTests.swift`

**Interfaces:**
- Consumes: `RelayFrame`, `ServerHandshake`, `ClientHandshake`, `RelaySecret` (Task 1); `RelayPairing.webSocketURL` (Task 2).
- Produces (used by Tasks 5 and 9):
  - `public final class RelayServer: @unchecked Sendable`
    - `public struct Policy: Sendable { var host: String; var port: UInt16; var allowRemote: @Sendable (String) -> Bool; var handshakeTimeout: TimeInterval = 10; var maxFailures = 5; var failureWindow: TimeInterval = 60; var lockout: TimeInterval = 60; init(host:port:allowRemote:) }`
    - `init(secret: RelaySecret, policy: Policy, log: @escaping @Sendable (String) -> Void = { _ in })`
    - `var onRelay: (@Sendable (Bool) -> Void)?`: an authenticated relay is connected (true) or the current one is gone (false)
    - `var onFrame: (@Sendable (RelayFrame) -> Void)?`: phone-direction frames from the authenticated relay only
    - `func start(ready: @escaping @Sendable (UInt16?) -> Void) throws` (bound port, or nil if the listener failed), `func stop()`, `func send(_ frame: RelayFrame)` (dropped without a relay)
  - `public final class RelayClient: @unchecked Sendable`
    - `public enum State: Equatable, Sendable { case idle, connecting, authenticated, failed(String) }`
    - `init(pairing: RelayPairing, pingInterval: TimeInterval = 60, handshakeTimeout: TimeInterval = 10)`
    - `var onState: (@Sendable (State) -> Void)?`, `var onFrame: (@Sendable (RelayFrame) -> Void)?` (Mac-direction frames after authentication)
    - `func connect()`, `func disconnect()`, `func send(_ frame: RelayFrame)` (dropped unless authenticated)
  - internal `enum WebSocketIO { static func parameters(serverKeepalive: Bool) -> NWParameters; static func send(_:on:); static func receive(on:_:); static func host(of: NWEndpoint) -> String? }`

- [ ] **Step 1: Write the failing tests**

`relay/Tests/ClaudeRelayTests/RelaySocketTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import ClaudeRelay

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ v: T) { lock.withLock { items.append(v) } }
    var all: [T] { lock.withLock { items } }
}

func eventually(_ seconds: Double = 5, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private let secret = RelaySecret.random()

private func loopbackPolicy(maxFailures: Int = 5, lockout: TimeInterval = 60,
                            allow: @escaping @Sendable (String) -> Bool = { $0 == "127.0.0.1" }) -> RelayServer.Policy {
    var p = RelayServer.Policy(host: "127.0.0.1", port: 0, allowRemote: allow)
    p.maxFailures = maxFailures
    p.lockout = lockout
    p.handshakeTimeout = 2
    return p
}

/// A started server, its bound port, and what it reported
private func startServer(_ policy: RelayServer.Policy = loopbackPolicy())
    async throws -> (RelayServer, UInt16, Box<Bool>, Box<RelayFrame>) {
    let server = RelayServer(secret: secret, policy: policy)
    let relays = Box<Bool>(), frames = Box<RelayFrame>()
    server.onRelay = { relays.add($0) }
    server.onFrame = { frames.add($0) }
    let port: UInt16? = await withCheckedContinuation { c in
        do { try server.start { c.resume(returning: $0) } } catch { c.resume(returning: nil) }
    }
    return (server, try #require(port), relays, frames)
}

private func client(_ port: UInt16, host: String = "127.0.0.1", secret s: RelaySecret = secret)
    -> (RelayClient, Box<RelayClient.State>, Box<RelayFrame>) {
    let c = RelayClient(pairing: RelayPairing(host: host, port: port, secret: s), handshakeTimeout: 2)
    let states = Box<RelayClient.State>(), frames = Box<RelayFrame>()
    c.onState = { states.add($0) }
    c.onFrame = { frames.add($0) }
    c.connect()
    return (c, states, frames)
}

@Test func authenticatedRelayExchangesFrames() async throws {
    let (server, port, relays, serverFrames) = try await startServer()
    defer { server.stop() }
    let (c, states, clientFrames) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) && relays.all == [true] })
    c.send(.fromBoard(Data([9, 0, 0, 0, 0x32])))
    c.send(.boardLink(true))
    #expect(await eventually { serverFrames.all == [.fromBoard(Data([9, 0, 0, 0, 0x32])), .boardLink(true)] })
    server.send(.toBoard(Data([2, 7, 0, 0, 0])))
    #expect(await eventually { clientFrames.all == [.toBoard(Data([2, 7, 0, 0, 0]))] })
    c.disconnect()
    #expect(await eventually { relays.all == [true, false] })
}

@Test func wrongSecretNeverReachesTheRelay() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (c, states, _) = client(port, secret: RelaySecret.random())
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    c.send(.fromBoard(Data([9, 0, 0, 0, 0x32])))
    try await Task.sleep(for: .milliseconds(200))
    #expect(relays.all.isEmpty && frames.all.isEmpty)
}

/// A raw WebSocket client that skips the handshake
private func rawConnection(_ port: UInt16) -> NWConnection {
    let c = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/relay")!),
                         using: WebSocketIO.parameters(serverKeepalive: false))
    c.start(queue: DispatchQueue(label: "raw"))
    return c
}

@Test func framesBeforeAuthCloseTheConnection() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let raw = rawConnection(port)
    defer { raw.cancel() }
    let ended = Box<Bool>()
    // First message from the server is the challenge; answer with a data frame instead of auth
    WebSocketIO.receive(on: raw) { _ in
        WebSocketIO.send(RelayFrame.fromBoard(Data([9, 0, 0, 0, 0x33])).encode(), on: raw)
        WebSocketIO.receive(on: raw) { r in if case .end = r { ended.add(true) } }
    }
    #expect(await eventually { !ended.all.isEmpty })
    #expect(relays.all.isEmpty && frames.all.isEmpty)
}

@Test func macFramesFromThePhoneCloseTheConnection() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains(.authenticated) })
    c.send(.toBoard(Data([0, 1, 0, 0, 0])))              // only the Mac may send this
    #expect(await eventually { relays.all == [true, false] })
    #expect(frames.all.isEmpty)
}

@Test func silentClientsTimeOut() async throws {
    let (server, port, relays, _) = try await startServer()
    defer { server.stop() }
    let raw = rawConnection(port)
    defer { raw.cancel() }
    let ended = Box<Bool>()
    WebSocketIO.receive(on: raw) { _ in                  // the challenge; then say nothing
        WebSocketIO.receive(on: raw) { r in if case .end = r { ended.add(true) } }
    }
    #expect(await eventually(4) { !ended.all.isEmpty })  // handshakeTimeout 2 s in the test policy
    #expect(relays.all.isEmpty)
}

@Test func lockoutAfterRepeatedFailures() async throws {
    let (server, port, relays, _) = try await startServer(loopbackPolicy(maxFailures: 2, lockout: 2))
    defer { server.stop() }
    for _ in 0..<2 {
        let (bad, states, _) = client(port, secret: RelaySecret.random())
        #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
        bad.disconnect()
    }
    let (locked, lockedStates, _) = client(port)        // the right secret, but the port is locked
    #expect(await eventually { lockedStates.all.contains { if case .failed = $0 { true } else { false } } })
    locked.disconnect()
    #expect(relays.all.isEmpty)
    try await Task.sleep(for: .milliseconds(2200))
    let (good, goodStates, _) = client(port)
    defer { good.disconnect() }
    #expect(await eventually { goodStates.all.contains(.authenticated) })
}

@Test func remotePolicyRefuses() async throws {
    let (server, port, relays, _) = try await startServer(loopbackPolicy(allow: { _ in false }))
    defer { server.stop() }
    let (c, states, _) = client(port)
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    #expect(relays.all.isEmpty)
}

@Test func bindsOnlyTheGivenAddress() async throws {
    // Bound to 127.0.0.1: the same port on ::1 (another address of this Mac) has no listener
    let (server, port, relays, _) = try await startServer(loopbackPolicy(allow: { _ in true }))
    defer { server.stop() }
    let (c, states, _) = client(port, host: "::1")
    defer { c.disconnect() }
    #expect(await eventually { states.all.contains { if case .failed = $0 { true } else { false } } })
    #expect(relays.all.isEmpty)
}

@Test func newRelayReplacesTheOldOne() async throws {
    let (server, port, relays, frames) = try await startServer()
    defer { server.stop() }
    let (first, firstStates, _) = client(port)
    defer { first.disconnect() }
    #expect(await eventually { firstStates.all.contains(.authenticated) })
    let (second, secondStates, secondFrames) = client(port)
    defer { second.disconnect() }
    #expect(await eventually { secondStates.all.contains(.authenticated) })
    #expect(await eventually { firstStates.all.last.map { if case .failed = $0 { true } else { false } } ?? false })
    #expect(relays.all == [true, true])                  // no "gone" for the replaced one
    server.send(.voiceBegin(4))
    #expect(await eventually { secondFrames.all == [.voiceBegin(4)] })
    second.send(.boardLink(true))
    #expect(await eventually { frames.all == [.boardLink(true)] })
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd relay && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'RelayServer'`).

- [ ] **Step 3: Implement the WebSocket helpers**

`relay/Sources/ClaudeRelay/WebSocketIO.swift`:

```swift
import Foundation
import Network

/// Binary WebSocket messages over Network.framework, shared by the server (Mac) and the client (iPhone).
enum WebSocketIO {
    /// WebSocket over plain TCP (Tailscale's WireGuard encrypts the path). The server adds TCP keepalive (idle 60 s,
    /// 15 s × 4 probes): the kernel notices a vanished iPhone without any app-level polling.
    static func parameters(serverKeepalive: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        if serverKeepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = RelayFrame.maxFrame
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    static func send(_ data: Data, on c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "relay", metadata: [meta])
        c.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    enum Received: Sendable { case binary(Data), control, end }

    /// One message: binary data, a ping / pong, or the end (close, error, a text message, nothing)
    static func receive(on c: NWConnection, _ handler: @escaping @Sendable (Received) -> Void) {
        c.receiveMessage { data, context, _, error in
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard error == nil, let meta else { handler(.end); return }
            switch meta.opcode {
            case .binary: handler(data.map(Received.binary) ?? .end)
            case .ping, .pong: handler(.control)
            default: handler(.end)
            }
        }
    }

    /// "100.101.102.103" / "fd7a:115c:a1e0::5" (zone dropped); nil for anything that is not an IP endpoint
    static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".split(separator: "%").first.map(String.init)
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Implement the server**

`relay/Sources/ClaudeRelay/RelayServer.swift`:

```swift
import Foundation
import Network

/// The daemon's end of the iPhone relay: a WebSocket listener bound to exactly one address (the Mac's Tailscale
/// address; loopback in tests), mutual HMAC handshake, one authenticated relay at a time (the newest wins).
/// Everything runs on one serial queue.
public final class RelayServer: @unchecked Sendable {
    public struct Policy: Sendable {
        public var host: String
        public var port: UInt16
        /// Remote addresses allowed to connect at all (TailscaleAddress.isTailscale in the daemon)
        public var allowRemote: @Sendable (String) -> Bool
        public var handshakeTimeout: TimeInterval = 10
        public var maxFailures = 5
        public var failureWindow: TimeInterval = 60
        public var lockout: TimeInterval = 60

        public init(host: String, port: UInt16, allowRemote: @escaping @Sendable (String) -> Bool) {
            self.host = host
            self.port = port
            self.allowRemote = allowRemote
        }
    }

    private final class Session {
        let connection: NWConnection
        let remote: String
        var handshake: ServerHandshake
        var authenticated = false
        var closed = false
        init(_ c: NWConnection, remote: String, handshake: ServerHandshake) {
            connection = c
            self.remote = remote
            self.handshake = handshake
        }
    }

    public var onRelay: (@Sendable (Bool) -> Void)?
    public var onFrame: (@Sendable (RelayFrame) -> Void)?

    private let secret: RelaySecret
    private let policy: Policy
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.relay")
    private var listener: NWListener?
    private var current: Session?
    private var failures: [Date] = []
    private var lockedUntil = Date.distantPast

    public init(secret: RelaySecret, policy: Policy, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secret = secret
        self.policy = policy
        self.log = log
    }

    /// `ready` gets the bound port once listening, or nil if the listener failed (address gone, port taken)
    public func start(ready: @escaping @Sendable (UInt16?) -> Void = { _ in }) throws {
        let params = WebSocketIO.parameters(serverKeepalive: true)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(policy.host),
                                                 port: NWEndpoint.Port(rawValue: policy.port) ?? .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready: ready(l?.port?.rawValue)
            case .failed(let e):
                self?.log("relay listener on \(self?.policy.host ?? "?") failed: \(e)")
                l?.cancel()
                ready(nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        queue.sync { listener = l }
        l.start(queue: queue)
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            if let s = current { close(s, "listener stopped", failed: false) }
        }
    }

    public func send(_ frame: RelayFrame) {
        queue.async { [self] in
            guard let s = current else { return }
            WebSocketIO.send(frame.encode(), on: s.connection)
        }
    }

    private func accept(_ c: NWConnection) {
        guard Date() >= lockedUntil else {
            log("relay: connection refused (locked after failed handshakes)")
            c.cancel()
            return
        }
        guard let remote = WebSocketIO.host(of: c.endpoint), policy.allowRemote(remote) else {
            log("relay: connection from \(c.endpoint) refused (not a Tailscale address)")
            c.cancel()
            return
        }
        let s = Session(c, remote: remote, handshake: ServerHandshake(secret: secret))
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                WebSocketIO.send(s.handshake.challenge.encode(), on: c)
                self.receive(s)
            case .failed, .cancelled:
                self.close(s, nil, failed: !s.authenticated)
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + policy.handshakeTimeout) { [weak self] in
            guard let self, !s.authenticated, !s.closed else { return }
            self.close(s, "relay: handshake from \(remote) timed out", failed: true)
        }
        c.start(queue: queue)
    }

    private func receive(_ s: Session) {
        WebSocketIO.receive(on: s.connection) { [weak self] r in
            guard let self else { return }
            self.queue.async { self.handle(s, r) }   // receive callbacks already run on `queue`; this keeps it explicit
        }
    }

    private func handle(_ s: Session, _ r: WebSocketIO.Received) {
        guard !s.closed else { return }
        switch r {
        case .end:
            close(s, s.authenticated ? "relay: iPhone disconnected" : nil, failed: !s.authenticated)
        case .control:
            receive(s)
        case .binary(let data):
            guard let frame = RelayFrame.decode(data, from: .phone) else {
                close(s, "relay: malformed or wrong-direction frame from \(s.remote)", failed: !s.authenticated)
                return
            }
            if s.authenticated {
                onFrame?(frame)
                receive(s)
                return
            }
            switch s.handshake.receive(frame) {
            case .accepted(let welcome):
                s.authenticated = true
                WebSocketIO.send(welcome.encode(), on: s.connection)
                if let old = current {                    // the newest relay wins; the old one goes quietly
                    old.closed = true
                    old.connection.cancel()
                }
                current = s
                log("relay: iPhone authenticated (\(s.remote))")
                onRelay?(true)
                receive(s)
            case .rejected:
                close(s, "relay: handshake from \(s.remote) rejected", failed: true)
            }
        }
    }

    private func close(_ s: Session, _ why: String?, failed: Bool) {
        guard !s.closed else { return }
        s.closed = true
        s.connection.cancel()
        if let why { log(why) }
        if failed { recordFailure() }
        if s === current {
            current = nil
            onRelay?(false)
        }
    }

    private func recordFailure() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < policy.failureWindow } + [now]
        if failures.count >= policy.maxFailures {
            lockedUntil = now.addingTimeInterval(policy.lockout)
            failures = []
            log("relay: \(policy.maxFailures) failed handshakes: refusing connections for \(Int(policy.lockout)) s")
        }
    }
}
```

- [ ] **Step 5: Implement the client**

`relay/Sources/ClaudeRelay/RelayClient.swift`:

```swift
import Foundation
import Network

/// The iPhone's end: connects to the pairing's ws:// URL, runs the handshake (and checks the Mac's proof), then
/// passes Mac-direction frames up. A WebSocket ping every `pingInterval` (≥ 30 s; no other polling); no pong within
/// 15 s ends the connection. Reconnecting is the caller's job (ClaudeRelayService: backoff + path changes).
public final class RelayClient: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, connecting, authenticated, failed(String) }

    public var onState: (@Sendable (State) -> Void)?
    public var onFrame: (@Sendable (RelayFrame) -> Void)?

    private let pairing: RelayPairing
    private let pingInterval: TimeInterval
    private let handshakeTimeout: TimeInterval
    private let queue = DispatchQueue(label: "relay.client")
    private var connection: NWConnection?
    private var handshake: ClientHandshake
    private var authenticated = false
    private var generation = 0
    private var state = State.idle

    public init(pairing: RelayPairing, pingInterval: TimeInterval = 60, handshakeTimeout: TimeInterval = 10) {
        self.pairing = pairing
        self.pingInterval = max(30, pingInterval)
        self.handshakeTimeout = handshakeTimeout
        handshake = ClientHandshake(secret: pairing.secret)
    }

    public func connect() {
        queue.async { [self] in
            guard connection == nil else { return }
            generation += 1
            let gen = generation
            handshake = ClientHandshake(secret: pairing.secret)
            authenticated = false
            let c = NWConnection(to: .url(pairing.webSocketURL), using: WebSocketIO.parameters(serverKeepalive: false))
            connection = c
            c.stateUpdateHandler = { [weak self] s in
                guard let self, gen == self.generation else { return }
                switch s {
                case .ready: self.receive(c, gen)
                case .waiting(let e): self.finish(.failed("Mac unreachable: \(e)"))   // the caller retries, with backoff
                case .failed(let e): self.finish(.failed("\(e)"))
                default: break
                }
            }
            report(.connecting)
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                guard let self, gen == self.generation, !self.authenticated else { return }
                self.finish(.failed("The Mac did not answer the pairing check"))
            }
        }
    }

    public func disconnect() { queue.async { self.finish(.idle) } }

    public func send(_ frame: RelayFrame) {
        queue.async { [self] in
            guard authenticated, let c = connection else { return }
            WebSocketIO.send(frame.encode(), on: c)
        }
    }

    private func receive(_ c: NWConnection, _ gen: Int) {
        WebSocketIO.receive(on: c) { [weak self] r in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch r {
                case .end: self.finish(.failed("Connection to the Mac closed"))
                case .control: self.receive(c, gen)
                case .binary(let data):
                    guard let frame = RelayFrame.decode(data, from: .mac) else {
                        self.finish(.failed("Unexpected data from the Mac"))
                        return
                    }
                    if self.authenticated {
                        self.onFrame?(frame)
                    } else {
                        switch self.handshake.receive(frame) {
                        case .send(let reply): WebSocketIO.send(reply.encode(), on: c)
                        case .authenticated:
                            self.authenticated = true
                            self.report(.authenticated)
                            self.schedulePing(c, gen)
                        case .rejected:
                            self.finish(.failed("Pairing check failed: scan the Mac's QR code again"))
                            return
                        }
                    }
                    self.receive(c, gen)
                }
            }
        }
    }

    private func schedulePing(_ c: NWConnection, _ gen: Int) {
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self, gen == self.generation, self.authenticated else { return }
            let answered = Flag()
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            meta.setPongHandler(self.queue) { _ in answered.set() }
            c.send(content: Data(), contentContext: .init(identifier: "ping", metadata: [meta]), isComplete: true,
                   completion: .contentProcessed { _ in })
            self.queue.asyncAfter(deadline: .now() + 15) {
                if gen == self.generation, !answered.value { self.finish(.failed("No answer from the Mac")) }
            }
            self.schedulePing(c, gen)
        }
    }

    private func finish(_ s: State) {
        generation += 1
        connection?.cancel()
        connection = nil
        authenticated = false
        report(s)
    }

    private func report(_ s: State) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
```

- [ ] **Step 6: Run the tests**

Run: `cd relay && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -5`
Expected: no warnings; all tests pass in well under a minute. If `bindsOnlyTheGivenAddress` connects, then `requiredLocalEndpoint` was not honoured. Do not paper over that: instead, also check each accepted connection's local endpoint (`c.currentPath?.localEndpoint`, compared with `WebSocketIO.host`) against `policy.host` in `.ready`, close it otherwise, and note it in the commit message. If Swift 6 strict concurrency complains about a capture, fix it with the queue-confinement pattern already used (state touched only on `queue`), not with `nonisolated(unsafe)`.

- [ ] **Step 7: Commit**

```bash
git add relay/Sources/ClaudeRelay/WebSocketIO.swift relay/Sources/ClaudeRelay/RelayServer.swift \
        relay/Sources/ClaudeRelay/RelayClient.swift relay/Tests/ClaudeRelayTests/RelaySocketTests.swift
git commit -m "relay: WebSocket server (one address, handshake, lockout, newest relay wins) and client (ping)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---

### Task 4: Mac: the board router and voice over the relay (pure)

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/BoardRouter.swift`, `mac/Sources/ClaudeBoardCore/RelayVoice.swift`
- Modify: `mac/Sources/ClaudeBoardCore/VoiceHub.swift` (`precheck`: ask the engine every time; remove `engineReady`)
- Test: `mac/Tests/ClaudeBoardCoreTests/BoardRouterTests.swift`, `mac/Tests/ClaudeBoardCoreTests/RelayVoiceTests.swift`

**Interfaces:**
- Consumes: `BoardLinking`, `BoardMessage`, `BoardInput` (existing), `VoiceEngine` / `VoiceStream` (existing, `VoiceHub.swift`), `RelayFrame` (Task 1).
- Produces (used by Task 5):
  - `public enum BoardPath: String, Sendable { case direct, relay }`
  - `public final class BoardRouter: BoardLinking, @unchecked Sendable`:
    - `init(send: @escaping @Sendable (BoardPath, BoardMessage) -> Void, log: @escaping @Sendable (String) -> Void = { _ in })`
    - `var onInput: (@Sendable (BoardInput) -> Void)?`, `var onConnectionChange: (@Sendable (Bool) -> Void)?`, `var onVoiceAudio: (@Sendable (Data) -> Void)?`
    - `var activePath: BoardPath? { get }`, `var isReady: Bool`, `func send(_:)`
    - `func pathReady(_ path: BoardPath, _ ready: Bool)`, `func input(_ input: BoardInput, from path: BoardPath)`, `func voiceAudio(_ packet: Data, from path: BoardPath)`, internal `func flush()` (tests)
  - `public final class RelayVoiceEngine: VoiceEngine, @unchecked Sendable`:
    - `static let notConnected = "Voice needs the iPhone relay"`
    - `init(send: @escaping @Sendable (RelayFrame) -> Void, finalTimeout: Duration = .seconds(15), log:)`
    - `func setStatus(_ why: String?)`, `func frame(_ f: RelayFrame)` (transcript / voiceFailed), `func relayGone()`
  - `public final class RoutedVoiceEngine: VoiceEngine, @unchecked Sendable { init(local: (any VoiceEngine)?, relay: any VoiceEngine, path: @escaping @Sendable () -> BoardPath?) }`

- [ ] **Step 1: Write the failing router tests**

`mac/Tests/ClaudeBoardCoreTests/BoardRouterTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

/// Router with every callback recorded as one ordered log
private final class RouterLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
    func clear() { lock.withLock { items.removeAll() } }
}

private func makeRouter() -> (BoardRouter, RouterLog) {
    let log = RouterLog()
    let r = BoardRouter(send: { path, m in log.add("send \(path.rawValue) \(m.encode().first!)") })
    r.onConnectionChange = { log.add($0 ? "up" : "down") }
    r.onInput = { log.add("input \($0)") }
    r.onVoiceAudio = { log.add("audio \($0.count)") }
    return (r, log)
}

private let mode = BoardInput.mode(.claude)

@Test func prefersDirect() {
    let (r, log) = makeRouter()
    r.pathReady(.relay, true); r.flush()
    #expect(r.activePath == .relay && log.all == ["up"])
    r.pathReady(.direct, true); r.flush()
    #expect(r.activePath == .direct)
    #expect(log.all == ["up", "down", "up"])            // a path change is a reconnect for everyone downstream
    log.clear()
    r.send(.sessionsClear)
    #expect(log.all == ["send direct 6"])
}

@Test func fallsBackToTheRelayWhenDirectDrops() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    r.pathReady(.direct, false); r.flush()
    #expect(r.activePath == .relay && log.all == ["down", "up"])
    log.clear()
    r.send(.cancel(id: 7))
    #expect(log.all == ["send relay 2"])
}

@Test func relayInputWhileDirectMeansTheBoardMovedOn() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    // The board lost the Mac first and reports its mode over the relay; the Mac has not noticed yet
    r.input(mode, from: .relay); r.flush()
    #expect(r.activePath == .relay)
    #expect(log.all == ["down", "up", "input \(mode)"])   // resync on the relay, then the mode (hub order)
    log.clear()
    r.pathReady(.direct, false); r.flush()               // the BLE loss arrives: nothing changes
    #expect(log.all.isEmpty && r.activePath == .relay)
}

@Test func directReturnTakesOver() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    r.input(mode, from: .relay); r.pathReady(.direct, false); r.flush()
    log.clear()
    r.pathReady(.direct, true); r.flush()                // reconnected: the board prefers it too
    #expect(r.activePath == .direct && log.all == ["down", "up"])
}

@Test func directInputClearsAStaleDirect() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    r.input(mode, from: .relay); r.flush()
    log.clear()
    r.input(mode, from: .direct); r.flush()              // the board is back on direct without a reconnect event
    #expect(r.activePath == .direct && log.all == ["down", "up", "input \(mode)"])
}

@Test func inputFromAPathThatIsNotReadyIsDropped() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.flush()
    log.clear()
    r.input(.choice(id: 5, .allow), from: .relay); r.flush()
    #expect(log.all.isEmpty && r.activePath == .direct)
}

@Test func noPathSendsNothing() {
    let (r, log) = makeRouter()
    #expect(!r.isReady)
    r.send(.sessionsClear)
    #expect(log.all.isEmpty)
    r.pathReady(.relay, true); r.pathReady(.relay, false); r.flush()
    #expect(log.all == ["up", "down"] && !r.isReady)
}

@Test func voiceAudioOnlyFromTheActivePath() {
    let (r, log) = makeRouter()
    r.pathReady(.direct, true); r.pathReady(.relay, true); r.flush()
    log.clear()
    r.voiceAudio(Data(count: 165), from: .relay)
    r.voiceAudio(Data(count: 85), from: .direct); r.flush()
    #expect(log.all == ["audio 85"])
}
```

- [ ] **Step 2: Write the failing voice tests**

`mac/Tests/ClaudeBoardCoreTests/RelayVoiceTests.swift`:

```swift
import ClaudeRelay
import Foundation
import Testing
@testable import ClaudeBoardCore

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [RelayFrame] = []
    private var partials: [String] = []
    func add(_ f: RelayFrame) { lock.withLock { frames.append(f) } }
    func partial(_ s: String) { lock.withLock { partials.append(s) } }
    var all: [RelayFrame] { lock.withLock { frames } }
    var said: [String] { lock.withLock { partials } }
}

@Test func statusIsWhatPrepareReports() async {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    #expect(await e.prepare() == RelayVoiceEngine.notConnected)
    e.setStatus(nil)
    #expect(await e.prepare() == nil)
    e.setStatus("Allow Speech Recognition for Live Translator on the iPhone")
    #expect(await e.prepare() == "Allow Speech Recognition for Live Translator on the iPhone")
}

@Test func beginPartialsAndFinal() async throws {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    let stream = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let session)? = sent.all.first else { Issue.record("no begin"); return }
    stream.feed([1, 2, 3])                                // audio never crosses the relay: nothing is sent
    e.frame(.transcript(session, final: false, "xin"))
    e.frame(.transcript(session, final: false, "xin chào"))
    async let text = stream.finish()
    try await Task.sleep(for: .milliseconds(50))
    #expect(sent.all == [.voiceBegin(session), .voiceFinish(session)])
    e.frame(.transcript(session, final: true, "Xin chào."))
    #expect(await text == "Xin chào.")
    #expect(sent.said == ["xin", "xin chào"])
}

@Test func staleTranscriptsAreIgnored() async throws {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) }, finalTimeout: .milliseconds(300))
    let first = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let old)? = sent.all.last else { return }
    await first.cancel()
    let second = try await e.begin { sent.partial($0) }
    guard case .voiceBegin(let new)? = sent.all.last else { return }
    #expect(old != new && sent.all.contains(.voiceCancel(old)))
    e.frame(.transcript(old, final: false, "old words"))
    e.frame(.transcript(old, final: true, "old final"))
    async let text = second.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.frame(.transcript(new, final: true, "new final"))
    #expect(await text == "new final")
    #expect(sent.said.isEmpty)
}

@Test func finishTimesOutToEmpty() async throws {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) }, finalTimeout: .milliseconds(200))
    let s = try await e.begin { _ in }
    #expect(await s.finish() == "")                       // the board then shows "Didn't catch that"
}

@Test func failedSessionEndsEmpty() async throws {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    let s = try await e.begin { _ in }
    guard case .voiceBegin(let id)? = sent.all.first else { return }
    async let text = s.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.frame(.voiceFailed(id, "Transcription did not start"))
    #expect(await text == "")
}

@Test func relayGoneEndsTheStream() async throws {
    let sent = Sent()
    let e = RelayVoiceEngine(send: { sent.add($0) })
    e.setStatus(nil)
    let s = try await e.begin { _ in }
    async let text = s.finish()
    try await Task.sleep(for: .milliseconds(50))
    e.relayGone()
    #expect(await text == "")
    #expect(await e.prepare() == RelayVoiceEngine.notConnected)
}

@Test func routedEngineFollowsThePath() async throws {
    let local = FakeEngine(finals: ["local"])
    let relayFrames = Sent()
    let relay = RelayVoiceEngine(send: { relayFrames.add($0) })
    let path = PathBox()
    let routed = RoutedVoiceEngine(local: local, relay: relay, path: { path.value })
    path.value = .relay
    #expect(await routed.prepare() == RelayVoiceEngine.notConnected)
    relay.setStatus(nil)
    #expect(await routed.prepare() == nil)
    _ = try await routed.begin { _ in }
    #expect(local.streams.isEmpty && relayFrames.all.count == 1)
    path.value = .direct
    local.unavailable = "Allow Speech Recognition for claude-board in System Settings"
    #expect(await routed.prepare() == "Allow Speech Recognition for claude-board in System Settings")
    local.unavailable = nil
    #expect(await routed.prepare() == nil)
    local.unavailable = "changed"                          // the Mac's own readiness is cached once ready
    #expect(await routed.prepare() == nil)
    _ = try await routed.begin { _ in }
    #expect(local.streams.count == 1)
    let noLocal = RoutedVoiceEngine(local: nil, relay: relay, path: { .direct })
    #expect(await noLocal.prepare() == "Voice needs macOS 26 on the Mac")
}

private final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var p: BoardPath?
    var value: BoardPath? { get { lock.withLock { p } } set { lock.withLock { p = newValue } } }
}
```

(`FakeEngine` is the existing fake in `VoiceHubTests.swift`, internal to the test target.)

- [ ] **Step 3: Run to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'BoardRouter'`).

- [ ] **Step 4: Implement the router**

`mac/Sources/ClaudeBoardCore/BoardRouter.swift`:

```swift
import Foundation

/// How the board is reached: direct BLE, or the iPhone relay over Tailscale.
public enum BoardPath: String, Sendable { case direct, relay }

/// The board as the daemon sees it, over whichever path is active (spec: "the daemon prefers direct BLE,
/// otherwise the relay"). Direct wins whenever it is ready, except when the board itself answers over the relay
/// while direct still looks ready: the board has lost the Mac link first (it prefers direct too), so the relay
/// stays active until direct reconnects or sends an input. Every change of active path reaches the daemon as
/// a disconnect then a connect: requests fall through, voice cancels, sessions resync, the clock is resent.
/// Path events are handled in order on one queue; `send` goes straight to the active path.
public final class BoardRouter: BoardLinking, @unchecked Sendable {
    public var onInput: (@Sendable (BoardInput) -> Void)?
    public var onConnectionChange: (@Sendable (Bool) -> Void)?
    public var onVoiceAudio: (@Sendable (Data) -> Void)?

    private let sendOn: @Sendable (BoardPath, BoardMessage) -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.router")
    private let lock = NSLock()
    private var ready: Set<BoardPath> = []   // lock
    private var active: BoardPath?           // lock
    private var directStale = false          // queue

    public init(send: @escaping @Sendable (BoardPath, BoardMessage) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sendOn = send
        self.log = log
    }

    public var activePath: BoardPath? { lock.withLock { active } }
    public var isReady: Bool { activePath != nil }

    public func send(_ message: BoardMessage) {
        guard let path = activePath else { return }
        sendOn(path, message)
    }

    public func pathReady(_ path: BoardPath, _ up: Bool) { queue.async { self.setReady(path, up) } }
    public func input(_ input: BoardInput, from path: BoardPath) { queue.async { self.route(input, path) } }
    public func voiceAudio(_ packet: Data, from path: BoardPath) {
        queue.async { if self.activePath == path { self.onVoiceAudio?(packet) } }
    }

    /// Waits until every event queued so far has been handled (tests)
    func flush() { queue.sync {} }

    private func setReady(_ path: BoardPath, _ up: Bool) {
        let changed = lock.withLock { () -> Bool in
            let was = ready.contains(path)
            if up { ready.insert(path) } else { ready.remove(path) }
            return was != up
        }
        if path == .direct && up { directStale = false }   // a fresh direct link: the board prefers it again
        if changed { log("\(path.rawValue) path \(up ? "ready" : "down")") }
        reselect()
    }

    private func route(_ input: BoardInput, _ path: BoardPath) {
        guard lock.withLock({ ready.contains(path) }) else {
            log("board input over the \(path.rawValue) path dropped: that path is not ready")
            return
        }
        if path == .relay && activePath == .direct {
            directStale = true
            log("the board answers over the relay: it lost the direct link")
        }
        if path == .direct { directStale = false }
        reselect()
        onInput?(input)
    }

    private func reselect() {
        let (old, new) = lock.withLock { () -> (BoardPath?, BoardPath?) in
            let pick: BoardPath? =
                ready.contains(.direct) && !directStale ? .direct
                : ready.contains(.relay) ? .relay
                : ready.contains(.direct) ? .direct
                : nil
            defer { active = pick }
            return (active, pick)
        }
        guard old != new else { return }
        log("board path: \(new?.rawValue ?? "none")")
        if old != nil { onConnectionChange?(false) }
        if new != nil { onConnectionChange?(true) }
    }
}
```

- [ ] **Step 5: Implement the relay voice engines**

`mac/Sources/ClaudeBoardCore/RelayVoice.swift`:

```swift
import ClaudeRelay
import Foundation

/// Voice when the board is on the relay: the iPhone transcribes the board audio itself and sends text only.
/// To VoiceHub this is just another engine: begin → voiceBegin(session), finish → voiceFinish and wait for the
/// final transcript (empty after `finalTimeout`, a failure or the relay going away), cancel → voiceCancel.
/// Transcripts for any other session are ignored.
public final class RelayVoiceEngine: VoiceEngine, @unchecked Sendable {
    public static let notConnected = "Voice needs the iPhone relay"

    private let sendFrame: @Sendable (RelayFrame) -> Void
    let finalTimeout: Duration
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var status: String? = RelayVoiceEngine.notConnected
    private var nextSession: UInt32 = 1
    private var stream: RelayVoiceStream?

    public init(send: @escaping @Sendable (RelayFrame) -> Void, finalTimeout: Duration = .seconds(15),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sendFrame = send
        self.finalTimeout = finalTimeout
        self.log = log
    }

    /// From the relay's voiceStatus frame (nil = the iPhone can transcribe)
    public func setStatus(_ why: String?) { lock.withLock { status = why } }

    public func prepare() async -> String? { lock.withLock { status } }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        let s = lock.withLock { () -> RelayVoiceStream in
            let id = nextSession
            nextSession = nextSession == .max ? 1 : nextSession + 1
            let s = RelayVoiceStream(session: id, engine: self, onPartial: onPartial)
            stream = s
            return s
        }
        sendFrame(.voiceBegin(s.session))
        return s
    }

    /// transcript / voiceFailed frames from the relay
    public func frame(_ f: RelayFrame) {
        switch f {
        case .transcript(let id, let final, let text):
            current(id)?.transcript(text, final: final)
        case .voiceFailed(let id, let why):
            log("voice over the relay failed: \(why)")
            current(id)?.transcript("", final: true)
        default:
            break
        }
    }

    /// The relay (or its board link) went away: an open capture ends empty
    public func relayGone() {
        let s = lock.withLock { () -> RelayVoiceStream? in
            defer { stream = nil; status = Self.notConnected }
            return stream
        }
        s?.transcript("", final: true)
    }

    fileprivate func send(_ f: RelayFrame) { sendFrame(f) }

    fileprivate func ended(_ s: RelayVoiceStream) { lock.withLock { if stream === s { stream = nil } } }

    fileprivate func timedOut(_ s: RelayVoiceStream) { log("voice over the relay: no final transcript from the iPhone") }

    private func current(_ id: UInt32) -> RelayVoiceStream? { lock.withLock { stream?.session == id ? stream : nil } }
}

final class RelayVoiceStream: VoiceStream, @unchecked Sendable {
    let session: UInt32
    private let engine: RelayVoiceEngine
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var final: String?
    private var waiter: CheckedContinuation<String, Never>?

    init(session: UInt32, engine: RelayVoiceEngine, onPartial: @escaping @Sendable (String) -> Void) {
        self.session = session
        self.engine = engine
        self.onPartial = onPartial
    }

    /// Audio never crosses the relay: the iPhone transcribes what the board sends it
    func feed(_ samples: [Int16]) {}

    func transcript(_ text: String, final isFinal: Bool) {
        if !isFinal {
            if lock.withLock({ final == nil }) { onPartial(text) }
            return
        }
        let w = lock.withLock { () -> CheckedContinuation<String, Never>? in
            guard final == nil else { return nil }
            final = text
            defer { waiter = nil }
            return waiter
        }
        engine.ended(self)
        w?.resume(returning: text)
    }

    func finish() async -> String {
        engine.send(.voiceFinish(session))
        let timeout = engine.finalTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            if self.lock.withLock({ self.final == nil }) { self.engine.timedOut(self) }
            self.transcript("", final: true)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { c in
            let done = lock.withLock { () -> String? in
                if let final { return final }
                waiter = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    func cancel() async {
        engine.send(.voiceCancel(session))
        transcript("", final: true)
    }
}

/// The engine for the active path: the Mac's own dictation (direct) or the iPhone's (relay). The Mac engine's
/// readiness is remembered once it is ready (it asks for permission and installs the model); the relay's
/// changes with the iPhone, so it is asked every time.
public final class RoutedVoiceEngine: VoiceEngine, @unchecked Sendable {
    enum Unavailable: Error { case noLocalEngine }

    private let local: (any VoiceEngine)?
    private let relay: any VoiceEngine
    private let path: @Sendable () -> BoardPath?
    private let lock = NSLock()
    private var localReady = false

    public init(local: (any VoiceEngine)?, relay: any VoiceEngine, path: @escaping @Sendable () -> BoardPath?) {
        self.local = local
        self.relay = relay
        self.path = path
    }

    public func prepare() async -> String? {
        if path() == .relay { return await relay.prepare() }
        guard let local else { return "Voice needs macOS 26 on the Mac" }
        if lock.withLock({ localReady }) { return nil }
        let why = await local.prepare()
        if why == nil { lock.withLock { localReady = true } }
        return why
    }

    public func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        if path() == .relay { return try await relay.begin(onPartial: onPartial) }
        guard let local else { throw Unavailable.noLocalEngine }
        return try await local.begin(onPartial: onPartial)
    }
}
```

- [ ] **Step 6: VoiceHub asks the engine on every capture**

In `mac/Sources/ClaudeBoardCore/VoiceHub.swift`, delete `private var engineReady = false` and replace the start of `precheck`:

```swift
    private func precheck(_ purpose: VoicePurpose, _ id: UInt32) async -> String? {
        guard let engine else { return "Voice needs macOS 26 on the Mac" }
        // Asked on every capture: on the relay path the answer follows the iPhone (RoutedVoiceEngine caches the Mac's)
        if let why = await engine.prepare() { return why }
        switch purpose {
```

- [ ] **Step 7: Run all Mac tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings; all tests pass, including the unchanged `VoiceHubTests`.

- [ ] **Step 8: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/BoardRouter.swift mac/Sources/ClaudeBoardCore/RelayVoice.swift \
        mac/Sources/ClaudeBoardCore/VoiceHub.swift mac/Tests/ClaudeBoardCoreTests/BoardRouterTests.swift \
        mac/Tests/ClaudeBoardCoreTests/RelayVoiceTests.swift
git commit -m "mac: board router (direct preferred, follows the board to the relay) and voice through the iPhone

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---
### Task 5: Mac: relay link, Tailscale-only listener lifecycle, and the daemon wiring

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/RelayLink.swift` (`RelayLink`, `RelayHost`, `RelayAddressWatcher`), `mac/Tests/ClaudeBoardCoreTests/RelayLinkTests.swift`
- Modify: `mac/Sources/claude-board/BoardLink.swift` (hello before "ready"), `mac/Sources/claude-board/main.swift` (router, relay, routed voice)

**Interfaces:**
- Consumes: `BoardRouter`, `BoardPath`, `RelayVoiceEngine`, `RoutedVoiceEngine` (Task 4); `RelayServer`, `RelayClient` (Task 3); `RelaySecretFile`, `RelayConfig` (Task 2); `TailscaleAddress` (Task 2); `BoardHello`, `BLEFraming` (Task 1).
- Produces:
  - `public final class RelayLink: @unchecked Sendable { init(log:); func connect(router: BoardRouter, voice: RelayVoiceEngine); func attach(_ send: (@Sendable (RelayFrame) -> Void)?); func send(_ f: RelayFrame); func sendToBoard(_ m: BoardMessage); func relayConnected(_ up: Bool); func frame(_ f: RelayFrame) }`
  - `public final class RelayHost: @unchecked Sendable { init(secret: RelaySecret, link: RelayLink, port: UInt16, allowRemote: @escaping @Sendable (String) -> Bool = TailscaleAddress.isTailscale, log:); var onListenerFailed: (@Sendable () -> Void)?; var onListening: (@Sendable (UInt16) -> Void)?; func addressChanged(_ host: String?) }`
  - `public final class RelayAddressWatcher: @unchecked Sendable { init(interfaces: @escaping @Sendable () -> [TailscaleAddress.Interface] = { TailscaleAddress.interfaces() }, onChange: @escaping @Sendable (String?) -> Void); func refresh(); func forceNext(); func start(queue: DispatchQueue) }`

- [ ] **Step 1: Write the failing tests**

`mac/Tests/ClaudeBoardCoreTests/RelayLinkTests.swift`:

```swift
import ClaudeRelay
import Foundation
import Testing
@testable import ClaudeBoardCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

private func until(_ seconds: Double = 5, _ cond: @escaping @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}

private func wired() -> (RelayLink, BoardRouter, RelayVoiceEngine, Log) {
    let log = Log()
    let link = RelayLink()
    let router = BoardRouter(send: { path, m in
        if path == .relay { link.sendToBoard(m) } else { log.add("direct \(m.encode().first!)") }
    })
    router.onInput = { log.add("input \($0)") }
    router.onConnectionChange = { log.add($0 ? "up" : "down") }
    let voice = RelayVoiceEngine(send: { link.send($0) })
    link.connect(router: router, voice: voice)
    link.attach { log.add("frame \($0.encode().map { String(format: "%02x", $0) }.joined())") }
    return (link, router, voice, log)
}

@Test func boardLinkFramesDriveTheRelayPath() async {
    let (link, router, _, log) = wired()
    link.relayConnected(true)
    link.frame(.boardLink(true)); router.flush()
    #expect(router.activePath == .relay && log.all == ["up"])
    router.send(.cancel(id: 7))
    #expect(log.all.last == "frame 010207000000")         // toBoard: the encoded message, unchanged
    link.frame(.fromBoard(Data([7, 0, 0, 0, 1]))); router.flush()
    #expect(log.all.last == "input \(BoardInput.choice(id: 7, .allow))")
    link.frame(.boardLink(false)); router.flush()
    #expect(router.activePath == nil && log.all.last == "down")
}

@Test func unreadableBoardInputIsDropped() {
    let (link, router, _, log) = wired()
    link.frame(.boardLink(true)); router.flush()
    link.frame(.fromBoard(Data([0, 0, 0, 0, 0x99]))); router.flush()
    #expect(!log.all.contains { $0.hasPrefix("input") })
}

@Test func relayGoneTakesThePathAndVoiceDown() async {
    let (link, router, voice, _) = wired()
    link.frame(.boardLink(true))
    link.frame(.voiceStatus(nil)); router.flush()
    #expect(await voice.prepare() == nil)
    link.relayConnected(false); router.flush()
    #expect(router.activePath == nil)
    #expect(await voice.prepare() == RelayVoiceEngine.notConnected)
}

@Test func transcriptsReachTheVoiceEngine() async throws {
    let (link, _, voice, log) = wired()
    let stream = try await voice.begin { _ in }
    #expect(log.all.last == "frame 1001000000")           // voiceBegin(1) through the attached server
    async let text = stream.finish()
    try await Task.sleep(for: .milliseconds(50))
    link.frame(.transcript(1, final: true, "Chạy test"))
    #expect(await text == "Chạy test")
}

private final class Ifs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TailscaleAddress.Interface] = []
    var value: [TailscaleAddress.Interface] { get { lock.withLock { list } } set { lock.withLock { list = newValue } } }
}

@Test func watcherReportsOnlyChanges() {
    let ifs = Ifs()
    let seen = Log()
    let w = RelayAddressWatcher(interfaces: { ifs.value }, onChange: { seen.add($0 ?? "none") })
    w.refresh()                                           // first look always reports
    ifs.value = [.init(name: "utun3", address: "100.101.102.103")]
    w.refresh(); w.refresh()
    ifs.value = [.init(name: "utun3", address: "100.101.102.104")]
    w.refresh()
    ifs.value = [.init(name: "en0", address: "100.101.102.104")]   // not a tunnel: not Tailscale
    w.refresh()
    w.forceNext(); w.refresh()                            // after a listener failure: report again
    #expect(seen.all == ["none", "100.101.102.103", "100.101.102.104", "none", "none"])
}

@Test func addressGoneStopsTheListener() async throws {
    // A real server on loopback (tests never need Tailscale), a real client, then the address goes away
    let secret = RelaySecret.random()
    let (link, router, _, _) = wired()
    let host = RelayHost(secret: secret, link: link, port: 0, allowRemote: { $0 == "127.0.0.1" })
    let port = Log()
    host.onListening = { port.add("\($0)") }
    host.addressChanged("127.0.0.1")
    #expect(await until { !port.all.isEmpty })
    let client = RelayClient(pairing: RelayPairing(host: "127.0.0.1", port: UInt16(port.all[0])!, secret: secret))
    let states = Log()
    client.onState = { states.add("\($0)") }
    client.connect()
    defer { client.disconnect() }
    #expect(await until { states.all.contains("authenticated") })
    client.send(.boardLink(true))
    #expect(await until { router.activePath == .relay })
    host.addressChanged(nil)                              // Tailscale went down: no listener, no relay path
    #expect(await until { router.activePath == nil })
    #expect(await until { states.all.last?.hasPrefix("failed") ?? false })
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd mac && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'RelayLink'`).

- [ ] **Step 3: Implement**

`mac/Sources/ClaudeBoardCore/RelayLink.swift`:

```swift
import ClaudeRelay
import Foundation
import Network

/// Joins the relay server to the router (path .relay) and to the relay voice engine. Never decides anything:
/// board inputs go through the router to the same handlers as direct ones (RequestQueue checks id and shape).
public final class RelayLink: @unchecked Sendable {
    private let lock = NSLock()
    private var router: BoardRouter?
    private var voice: RelayVoiceEngine?
    private var sendFrame: (@Sendable (RelayFrame) -> Void)?
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) { self.log = log }

    public func connect(router: BoardRouter, voice: RelayVoiceEngine) {
        lock.withLock {
            self.router = router
            self.voice = voice
        }
    }

    /// Where frames for the iPhone go (the current RelayServer), nil while there is no listener
    public func attach(_ send: (@Sendable (RelayFrame) -> Void)?) { lock.withLock { sendFrame = send } }

    public func send(_ f: RelayFrame) { lock.withLock { sendFrame }?(f) }

    /// The router's relay path: one encoded board message, unchanged
    public func sendToBoard(_ m: BoardMessage) { send(.toBoard(m.encode())) }

    /// The server's authenticated relay came or went
    public func relayConnected(_ up: Bool) {
        guard !up else { return }   // the path is ready only once the iPhone also holds the board's relay role
        let (router, voice) = lock.withLock { (self.router, self.voice) }
        router?.pathReady(.relay, false)
        voice?.relayGone()
    }

    public func frame(_ f: RelayFrame) {
        let (router, voice) = lock.withLock { (self.router, self.voice) }
        switch f {
        case .boardLink(let up):
            log("relay: board link \(up ? "up" : "down") on the iPhone")
            router?.pathReady(.relay, up)
            if !up { voice?.relayGone() }
        case .fromBoard(let data):
            guard let input = BoardInput.decode(data) else {
                log("relay: unreadable board input dropped (\(data.count) bytes)")
                return
            }
            router?.input(input, from: .relay)
        case .voiceStatus(let why):
            voice?.setStatus(why)
            log("relay: iPhone voice \(why ?? "ready")")
        case .transcript, .voiceFailed:
            voice?.frame(f)
        default:
            break   // Mac-direction frames never get here (RelayFrame.decode checks the sender)
        }
    }
}

/// The relay server for the current Tailscale address: nothing without one, a new server when it changes.
/// The listener is bound to that one address; nothing else on the Mac (LAN, loopback, any) ever listens.
public final class RelayHost: @unchecked Sendable {
    public var onListenerFailed: (@Sendable () -> Void)?
    public var onListening: (@Sendable (UInt16) -> Void)?

    private let secret: RelaySecret
    private let link: RelayLink
    private let port: UInt16
    private let allowRemote: @Sendable (String) -> Bool
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "claude-board.relay-host")
    private var server: RelayServer?
    private var host: String?

    public init(secret: RelaySecret, link: RelayLink, port: UInt16,
                allowRemote: @escaping @Sendable (String) -> Bool = { TailscaleAddress.isTailscale($0) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secret = secret
        self.link = link
        self.port = port
        self.allowRemote = allowRemote
        self.log = log
    }

    public func addressChanged(_ newHost: String?) {
        queue.async { [self] in
            if let old = server {
                old.stop()
                server = nil
                link.attach(nil)
                link.relayConnected(false)
            }
            host = newHost
            guard let newHost else {
                log("iPhone relay off: no Tailscale address on this Mac")
                return
            }
            let s = RelayServer(secret: secret,
                                policy: .init(host: newHost, port: port, allowRemote: allowRemote), log: log)
            s.onRelay = { [link] up in link.relayConnected(up) }
            s.onFrame = { [link] f in link.frame(f) }
            server = s
            link.attach { [weak s] f in s?.send(f) }
            do {
                try s.start { [weak self] bound in
                    guard let self else { return }
                    if let bound {
                        self.log("iPhone relay listening on \(newHost) port \(bound) (Tailscale only)")
                        self.onListening?(bound)
                    } else {
                        self.onListenerFailed?()
                    }
                }
            } catch {
                log("iPhone relay: listener not created: \(error)")
                onListenerFailed?()
            }
        }
    }
}

/// Reports the Tailscale address to listen on whenever it changes, re-checking on every network path change
/// (NWPathMonitor: event-driven, no polling).
public final class RelayAddressWatcher: @unchecked Sendable {
    private let interfaces: @Sendable () -> [TailscaleAddress.Interface]
    private let onChange: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var reported = false
    private var last: String?
    private var monitor: NWPathMonitor?

    public init(interfaces: @escaping @Sendable () -> [TailscaleAddress.Interface] = { TailscaleAddress.interfaces() },
                onChange: @escaping @Sendable (String?) -> Void) {
        self.interfaces = interfaces
        self.onChange = onChange
    }

    public func refresh() {
        let now = TailscaleAddress.pick(interfaces())
        let changed = lock.withLock { () -> Bool in
            guard !reported || last != now else { return false }
            reported = true
            last = now
            return true
        }
        if changed { onChange(now) }
    }

    /// The next refresh reports even an unchanged address (after a listener failure: try binding again)
    public func forceNext() { lock.withLock { reported = false } }

    public func start(queue: DispatchQueue) {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        lock.withLock { monitor = m }
        m.start(queue: queue)
        queue.async { self.refresh() }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: BoardLink says hello before it reports "ready"**

In `mac/Sources/claude-board/BoardLink.swift`, add `import ClaudeRelay`. In `peripheral(_:didUpdateNotificationStateFor:error:)`, just before `subscribed = true`, insert:

```swift
        // Phase 5: the board gives this connection the Mac role only after the hello (kind 9 "mac"), written
        // before anything else so it is first in the request characteristic's write queue
        if let request {
            for chunk in BLEFraming.chunks(BoardHello.mac, maxChunk: p.maximumWriteValueLength(for: .withoutResponse)) {
                p.writeValue(chunk, for: request, type: .withResponse)
            }
        }
```

Update the class comment ("so the link is 'ready' only once the answer subscription is confirmed") with: "…and the hello written: the board ignores a subscriber that has not said hello".

- [ ] **Step 6: Wire the daemon**

In `mac/Sources/claude-board/main.swift`, add `import ClaudeRelay`. Then restructure the top (after the `--transcribe` and `--pair` blocks) so that everything that used `board` as the board goes through the router. The resulting section reads:

```swift
let board = BoardLink()
// The iPhone relay (Tailscale WebSocket) is the second path to the board; the router prefers direct BLE
let relayLink = RelayLink(log: log)
let router = BoardRouter(send: { path, message in
    switch path {
    case .direct: board.send(message)
    case .relay: relayLink.sendToBoard(message)
    }
}, log: log)
let relayVoice = RelayVoiceEngine(send: { relayLink.send($0) }, log: log)
relayLink.connect(router: router, voice: relayVoice)
board.onInput = { router.input($0, from: .direct) }
board.onConnectionChange = { router.pathReady(.direct, $0) }
board.onVoiceAudio = { router.voiceAudio($0, from: .direct) }

let requests = RequestQueue(send: { router.send($0) })
```

Keep the hub, `hubEvents` and `voiceEvents` code as is, with these changes:
- the local engine stays `voiceEngine`. `VoiceHub(engine:)` now gets `RoutedVoiceEngine(local: voiceEngine, relay: relayVoice, path: { router.activePath })`.
- `board.onVoiceAudio = { packet in voiceFeed.yield … }` becomes `router.onVoiceAudio = { packet in voiceFeed.yield { await voice.audio(packet) } }`.
- `board.onInput = { input in switch … }` becomes `router.onInput = { input in switch … }` (same body).
- `board.onConnectionChange = { up in … board.send(.timeSync()) … }` becomes `router.onConnectionChange = { up in … router.send(.timeSync()) … }` (same body otherwise).
- the clock observers send `router.send(.timeSync())`.
- `HookProcessor(board: router, requests: requests, hub: hub, log: log)`.
- the "voice unavailable: needs macOS 26" log stays. Relay voice is announced by `RelayLink`.

After the expiry timer and before the socket section, add the relay listener:

```swift
// iPhone relay: listen on this Mac's Tailscale address only (never any other interface), with the secret from
// `claude-board --pair`. The address is re-checked on every network change; no address, no listener.
func startRelay() -> [AnyObject] {
    switch RelaySecretFile.load(path: RelayConfig.secretPath) {
    case .success(let secret):
        let relayHost = RelayHost(secret: secret, link: relayLink, port: RelayConfig.port, log: log)
        let watcher = RelayAddressWatcher { relayHost.addressChanged($0) }
        relayHost.onListenerFailed = {
            // e.g. Tailscale assigned the address a moment after the interface appeared: try once more in 30 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { watcher.forceNext(); watcher.refresh() }
        }
        watcher.start(queue: DispatchQueue(label: "claude-board.netpath"))
        return [relayHost, watcher]
    case .failure(let e):
        log("iPhone relay off: \(e) (run ~/.claude-board/bin/claude-board --pair)")
        return []
    }
}
let relayKeepAlive = startRelay()
```

Then replace the last line `dispatchMain()` with `withExtendedLifetime(relayKeepAlive) { dispatchMain() }`, which keeps the relay objects alive for the daemon's lifetime.

- [ ] **Step 7: Build, test, smoke**

Run:
```bash
cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3
swift build -c release 2>&1 | tail -1
```
Expected: no warnings; all tests pass; the release build links. Do not reinstall the live daemon in this task. Task 7 installs it together with the matching firmware: the new daemon works with the old firmware (pre-Phase-5 boards log kind 9 as unknown), but the new firmware needs the new daemon.

- [ ] **Step 8: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/RelayLink.swift mac/Tests/ClaudeBoardCoreTests/RelayLinkTests.swift \
        mac/Sources/claude-board/BoardLink.swift mac/Sources/claude-board/main.swift
git commit -m "mac: daemon reaches the board directly or through the iPhone relay (Tailscale-only listener, mac hello)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---

### Task 6: Firmware: link roles and path selection, and the kind 9 hello (host-tested)

**Files:**
- Create: `firmware/main/claude_link.h`, `firmware/main/claude_link.c`, `firmware/test/test_claude_link.c`
- Modify: `firmware/main/claude_proto.h` (kind 9, `claude_parse_hello`, header comment), `firmware/main/claude_proto.c`, `firmware/test/test_claude_proto.c`, `firmware/main/CMakeLists.txt` (add `"claude_link.c"` after `"claude_proto.c"`)

**Interfaces:**
- Consumes: `claude_msg_t` (existing).
- Produces (used by Task 7):
  - `claude_proto.h`: `CLAUDE_LINK = 9` in `claude_kind_t`; `#define CLAUDE_HELLO_NONE 0`, `CLAUDE_HELLO_MAC 1`, `CLAUDE_HELLO_RELAY 2`; `int claude_parse_hello(const claude_msg_t *m);`
  - `claude_link.h`: `CLAUDE_LINK_PEERS` (3), `CLAUDE_CONN_NONE` (0xffff), `claude_role_t`, `claude_peer_t`, `claude_links_t`, `claude_link_state_t { uint16_t active; bool relayed; bool voice; uint16_t mtu; }`, `claude_link_ev_t`, plus the functions `claude_links_init`, `claude_links_slot`, `claude_links_answer`, `claude_links_voice`, `claude_links_mtu`, `claude_links_phone`, `claude_links_disconnected`, `claude_links_hello`, `claude_links_may_write`, `claude_links_state`, `claude_link_events` (signatures below).

- [ ] **Step 1: Write the failing tests**

`firmware/test/test_claude_link.c`:

```c
// firmware/test/test_claude_link.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_link test_claude_link.c ../main/claude_link.c && /tmp/test_claude_link
#include <assert.h>
#include <stdio.h>
#include "claude_link.h"

#define MAC   1
#define PHONE 2
#define OTHER 3
#define MIN_MTU 168

static claude_links_t fresh(void)
{
    claude_links_t l;
    claude_links_init(&l);
    return l;
}

static claude_link_state_t st(const claude_links_t *l)
{
    return claude_links_state(l, MIN_MTU);
}

static void mac_needs_subscription_and_hello(void)
{
    claude_links_t l = fresh();
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));          /* not subscribed: refused */
    assert(!claude_links_may_write(&l, MAC));
    assert(claude_links_answer(&l, MAC, true));
    assert(claude_links_may_write(&l, MAC));
    assert(st(&l).active == CLAUDE_CONN_NONE);                       /* subscribed is not enough */
    assert(claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));
    claude_link_state_t s = st(&l);
    assert(s.active == MAC && !s.relayed && !s.voice);
}

static void restored_subscription_without_hello_is_nothing(void)
{
    /* iOS reconnects for ANCS without the app: NimBLE restores the bonded answer CCCD on encryption */
    claude_links_t l = fresh();
    claude_links_answer(&l, PHONE, true);
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void relay_only_on_the_phone_link(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, OTHER, true);
    assert(!claude_links_hello(&l, OTHER, CLAUDE_ROLE_RELAY));      /* no translator audio role */
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    assert(claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY));
    claude_link_state_t s = st(&l);
    assert(s.active == PHONE && s.relayed);
}

static void mac_never_on_the_phone_link(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    assert(!claude_links_hello(&l, PHONE, CLAUDE_ROLE_MAC));
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void mac_preferred_over_relay(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC);
    claude_links_disconnected(&l, MAC);                              /* the Mac walks out of range */
    claude_link_state_t s = st(&l);
    assert(s.active == PHONE && s.relayed);
    claude_links_answer(&l, MAC, true);                              /* back: a new hello makes it active again */
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC);
}

static void second_role_holder_is_refused(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    claude_links_answer(&l, OTHER, true);
    assert(!claude_links_hello(&l, OTHER, CLAUDE_ROLE_MAC));
    assert(claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC));            /* the same hello again is harmless */
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_RELAY));         /* a different one is refused */
    assert(!claude_links_hello(&l, MAC, CLAUDE_ROLE_NONE));
    assert(st(&l).active == MAC);
}

static void unsubscribe_clears_the_role(void)
{
    claude_links_t l = fresh();
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    claude_links_answer(&l, MAC, false);
    assert(st(&l).active == CLAUDE_CONN_NONE);
    assert(!claude_links_may_write(&l, MAC));
    claude_links_answer(&l, MAC, true);                              /* resubscribing needs a new hello */
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void phone_role_lost_drops_the_relay(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_phone(&l, CLAUDE_CONN_NONE);                        /* the translator app closed its audio */
    assert(st(&l).active == CLAUDE_CONN_NONE);
}

static void voice_follows_the_active_link_and_its_mtu(void)
{
    claude_links_t l = fresh();
    claude_links_phone(&l, PHONE);
    claude_links_answer(&l, PHONE, true);
    claude_links_hello(&l, PHONE, CLAUDE_ROLE_RELAY);
    claude_links_voice(&l, PHONE, true);
    assert(!st(&l).voice);                                           /* default MTU 23 */
    claude_links_mtu(&l, PHONE, 185);
    assert(st(&l).voice && st(&l).mtu == 185);
    claude_links_answer(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).active == MAC && !st(&l).voice);                   /* the Mac has not subscribed to voice */
    claude_links_mtu(&l, MAC, 247);
    claude_links_voice(&l, MAC, true);
    assert(st(&l).voice && st(&l).mtu == 247);
}

static void mtu_before_subscription_is_kept(void)
{
    claude_links_t l = fresh();
    claude_links_mtu(&l, MAC, 247);                                  /* MTU exchange comes first */
    claude_links_answer(&l, MAC, true);
    claude_links_voice(&l, MAC, true);
    claude_links_hello(&l, MAC, CLAUDE_ROLE_MAC);
    assert(st(&l).voice);
}

static void slots_full_is_refused(void)
{
    claude_links_t l = fresh();
    assert(claude_links_answer(&l, 10, true));
    assert(claude_links_answer(&l, 11, true));
    assert(claude_links_answer(&l, 12, true));
    assert(!claude_links_answer(&l, 13, true));
    assert(!claude_links_may_write(&l, 13));
    assert(claude_links_answer(&l, 13, false));                      /* turning off an unknown link is fine */
    claude_links_disconnected(&l, 10);
    assert(claude_links_answer(&l, 13, true));                       /* the slot came back */
    assert(claude_links_slot(&l, 13) >= 0 && claude_links_slot(&l, 10) == -1);
}

static void link_events_for_a_switch_with_voice(void)
{
    claude_link_ev_t ev[3];
    claude_link_state_t none = { .active = CLAUDE_CONN_NONE };
    claude_link_state_t mac_voice = { .active = MAC, .voice = true, .mtu = 247 };
    claude_link_state_t relay_voice = { .active = PHONE, .relayed = true, .voice = true, .mtu = 185 };
    claude_link_state_t relay_plain = { .active = PHONE, .relayed = true, .mtu = 185 };

    assert(claude_link_events(none, none, ev) == 0);
    assert(claude_link_events(none, mac_voice, ev) == 2 && ev[0] == CLAUDE_LINK_EV_UP && ev[1] == CLAUDE_LINK_EV_VOICE_ON);
    /* Mac → relay: down (ends voice), up, voice again on the new link */
    assert(claude_link_events(mac_voice, relay_voice, ev) == 3);
    assert(ev[0] == CLAUDE_LINK_EV_DOWN && ev[1] == CLAUDE_LINK_EV_UP && ev[2] == CLAUDE_LINK_EV_VOICE_ON);
    assert(claude_link_events(relay_voice, relay_plain, ev) == 1 && ev[0] == CLAUDE_LINK_EV_VOICE_OFF);
    assert(claude_link_events(relay_plain, relay_voice, ev) == 1 && ev[0] == CLAUDE_LINK_EV_VOICE_ON);
    assert(claude_link_events(relay_voice, none, ev) == 1 && ev[0] == CLAUDE_LINK_EV_DOWN);
    /* an MTU change that keeps voice on is no event */
    claude_link_state_t relay_voice_bigger = relay_voice;
    relay_voice_bigger.mtu = 247;
    assert(claude_link_events(relay_voice, relay_voice_bigger, ev) == 0);
}

int main(void)
{
    mac_needs_subscription_and_hello();
    restored_subscription_without_hello_is_nothing();
    relay_only_on_the_phone_link();
    mac_never_on_the_phone_link();
    mac_preferred_over_relay();
    second_role_holder_is_refused();
    unsubscribe_clears_the_role();
    phone_role_lost_drops_the_relay();
    voice_follows_the_active_link_and_its_mtu();
    mtu_before_subscription_is_kept();
    slots_full_is_refused();
    link_events_for_a_switch_with_voice();
    puts("claude_link: all tests passed");
    return 0;
}
```

In `firmware/test/test_claude_proto.c` add, and call it from `main` after `voice_encoders_refuse_bad_input();`:

```c
static void hello_parses(void)
{
    /* Shared vector with the Swift side (BoardHello.mac / .relay), one chunk each */
    claude_rx_t rx = { 0 };
    claude_msg_t m;
    uint8_t mac[] = { 0x03, 9, 0, 0, 0, 0, 'm', 'a', 'c' };
    assert(claude_rx_feed(&rx, mac, sizeof mac, &m) && m.kind == CLAUDE_LINK);
    assert(claude_parse_hello(&m) == CLAUDE_HELLO_MAC);
    uint8_t relay[] = { 0x03, 9, 0, 0, 0, 0, 'r', 'e', 'l', 'a', 'y' };
    assert(claude_rx_feed(&rx, relay, sizeof relay, &m));
    assert(claude_parse_hello(&m) == CLAUDE_HELLO_RELAY);

    claude_msg_t bad = { .kind = CLAUDE_LINK, .id = 0 };
    const char *texts[] = { "Mac", "relay\n", "", "mac ", "macrelay" };
    for (size_t i = 0; i < sizeof texts / sizeof texts[0]; i++) {
        snprintf(bad.text, sizeof bad.text, "%s", texts[i]);
        assert(claude_parse_hello(&bad) == CLAUDE_HELLO_NONE);
    }
    snprintf(bad.text, sizeof bad.text, "mac");
    bad.id = 1;
    assert(claude_parse_hello(&bad) == CLAUDE_HELLO_NONE);           /* id must be 0 */
    bad.id = 0;
    bad.kind = CLAUDE_FINISHED;
    assert(claude_parse_hello(&bad) == CLAUDE_HELLO_NONE);           /* only kind 9 */
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd firmware/test && cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_link test_claude_link.c ../main/claude_link.c && /tmp/test_claude_link`
Expected: `claude_link.h: No such file or directory`.

- [ ] **Step 3: Implement**

In `firmware/main/claude_proto.h`: add `CLAUDE_LINK = 9,` after `CLAUDE_VOICE = 8,`. Add this line to the Mac → board list in the header comment:
` *   9 link hello      id 0          "mac" | "relay"  (once per subscriber, before anything else; claude_link.h)`
Change "Mac -> board (request characteristic)" to "Mac or iPhone relay -> board (request characteristic)". Then add:

```c
/* Link hello (kind 9): who is subscribing. Anything but exactly "mac" / "relay" with id 0 is NONE. */
#define CLAUDE_HELLO_NONE  0
#define CLAUDE_HELLO_MAC   1
#define CLAUDE_HELLO_RELAY 2
int claude_parse_hello(const claude_msg_t *m);
```

In `firmware/main/claude_proto.c` append:

```c
int claude_parse_hello(const claude_msg_t *m)
{
    if (m->kind != CLAUDE_LINK || m->id != 0) {
        return CLAUDE_HELLO_NONE;
    }
    if (strcmp(m->text, "mac") == 0) {
        return CLAUDE_HELLO_MAC;
    }
    if (strcmp(m->text, "relay") == 0) {
        return CLAUDE_HELLO_RELAY;
    }
    return CLAUDE_HELLO_NONE;
}
```

`firmware/main/claude_link.h`:

```c
/*
 * Which BLE connection is the board's Claude link (pure, host-tested in firmware/test/test_claude_link.c).
 *
 * A connection gets a role only from its hello (claude_proto.h kind 9), written after it subscribed to the answer
 * characteristic: "mac" (the daemon, direct) on any connection except the translator app's, "relay" (the iPhone
 * app) only on the connection that holds the translator audio role. One holder per role. A restored (bonded) CCCD
 * without a hello is no role. The active link is the Mac, otherwise the relay. Voice is live when the active link
 * subscribed to the voice characteristic and its MTU fits one audio frame.
 * All calls from the NimBLE host task (ble_link.c).
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLAUDE_LINK_PEERS 3
#define CLAUDE_CONN_NONE  0xffff   /* BLE_HS_CONN_HANDLE_NONE */

typedef enum {
    CLAUDE_ROLE_NONE = 0,
    CLAUDE_ROLE_MAC = 1,
    CLAUDE_ROLE_RELAY = 2,
} claude_role_t;

typedef struct {
    uint16_t conn;        /* CLAUDE_CONN_NONE: free slot */
    bool answer;          /* answer CCCD on (written or restored) */
    bool voice;           /* voice CCCD on */
    claude_role_t role;   /* from the hello; cleared with the answer CCCD */
    uint16_t mtu;
} claude_peer_t;

typedef struct {
    claude_peer_t peer[CLAUDE_LINK_PEERS];
    uint16_t phone;       /* the connection holding the translator audio role */
} claude_links_t;

typedef struct {
    uint16_t active;      /* CLAUDE_CONN_NONE without a Claude link */
    bool relayed;         /* the active link is the iPhone relay */
    bool voice;
    uint16_t mtu;         /* of the active link, 0 without one */
} claude_link_state_t;

typedef enum {
    CLAUDE_LINK_EV_DOWN,       /* app_on_claude_link(false) (also ends voice) */
    CLAUDE_LINK_EV_UP,         /* app_on_claude_link(true) */
    CLAUDE_LINK_EV_VOICE_OFF,  /* app_on_claude_voice_link(false) */
    CLAUDE_LINK_EV_VOICE_ON,   /* app_on_claude_voice_link(true) */
} claude_link_ev_t;

void claude_links_init(claude_links_t *l);
/* Slot index of conn, -1 when unknown */
int claude_links_slot(const claude_links_t *l, uint16_t conn);
/* Answer / voice CCCD on or off. false: no free slot for a new connection (turning off never fails) */
bool claude_links_answer(claude_links_t *l, uint16_t conn, bool on);
bool claude_links_voice(claude_links_t *l, uint16_t conn, bool on);
void claude_links_mtu(claude_links_t *l, uint16_t conn, uint16_t mtu);
/* The translator audio role moved (CLAUDE_CONN_NONE: nobody); a relay elsewhere loses its role */
void claude_links_phone(claude_links_t *l, uint16_t conn);
void claude_links_disconnected(claude_links_t *l, uint16_t conn);
/* The hello of conn. false: refused (not subscribed, wrong connection for the role, role held elsewhere, or a
 * different role than the one it already has) */
bool claude_links_hello(claude_links_t *l, uint16_t conn, claude_role_t role);
/* Request writes are taken (into that link's reassembly buffer) only from answer-subscribed connections */
bool claude_links_may_write(const claude_links_t *l, uint16_t conn);
claude_link_state_t claude_links_state(const claude_links_t *l, uint16_t voice_min_mtu);
/* What the app must be told, in order, when the state goes from `was` to `now`. Returns the count (<= 3). */
size_t claude_link_events(claude_link_state_t was, claude_link_state_t now, claude_link_ev_t out[3]);
```

`firmware/main/claude_link.c`:

```c
#include "claude_link.h"

#define DEFAULT_MTU 23

static void clear(claude_peer_t *p)
{
    *p = (claude_peer_t){ .conn = CLAUDE_CONN_NONE, .mtu = DEFAULT_MTU };
}

void claude_links_init(claude_links_t *l)
{
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        clear(&l->peer[i]);
    }
    l->phone = CLAUDE_CONN_NONE;
}

int claude_links_slot(const claude_links_t *l, uint16_t conn)
{
    if (conn == CLAUDE_CONN_NONE) {
        return -1;
    }
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        if (l->peer[i].conn == conn) {
            return i;
        }
    }
    return -1;
}

static claude_peer_t *find_or_add(claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    if (i >= 0) {
        return &l->peer[i];
    }
    if (conn == CLAUDE_CONN_NONE) {
        return NULL;
    }
    for (i = 0; i < CLAUDE_LINK_PEERS; i++) {
        if (l->peer[i].conn == CLAUDE_CONN_NONE) {
            clear(&l->peer[i]);
            l->peer[i].conn = conn;
            return &l->peer[i];
        }
    }
    return NULL;
}

bool claude_links_answer(claude_links_t *l, uint16_t conn, bool on)
{
    int i = claude_links_slot(l, conn);
    claude_peer_t *p = on ? find_or_add(l, conn) : (i >= 0 ? &l->peer[i] : NULL);
    if (p == NULL) {
        return !on;
    }
    p->answer = on;
    if (!on) {
        p->role = CLAUDE_ROLE_NONE;
    }
    return true;
}

bool claude_links_voice(claude_links_t *l, uint16_t conn, bool on)
{
    int i = claude_links_slot(l, conn);
    claude_peer_t *p = on ? find_or_add(l, conn) : (i >= 0 ? &l->peer[i] : NULL);
    if (p == NULL) {
        return !on;
    }
    p->voice = on;
    return true;
}

void claude_links_mtu(claude_links_t *l, uint16_t conn, uint16_t mtu)
{
    claude_peer_t *p = find_or_add(l, conn);
    if (p != NULL) {
        p->mtu = mtu;
    }
}

void claude_links_phone(claude_links_t *l, uint16_t conn)
{
    l->phone = conn;
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        if (l->peer[i].role == CLAUDE_ROLE_RELAY && l->peer[i].conn != conn) {
            l->peer[i].role = CLAUDE_ROLE_NONE;
        }
    }
}

void claude_links_disconnected(claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    if (i >= 0) {
        clear(&l->peer[i]);
    }
    if (l->phone == conn) {
        l->phone = CLAUDE_CONN_NONE;
    }
}

bool claude_links_hello(claude_links_t *l, uint16_t conn, claude_role_t role)
{
    int i = claude_links_slot(l, conn);
    if (i < 0 || !l->peer[i].answer || role == CLAUDE_ROLE_NONE) {
        return false;
    }
    claude_peer_t *p = &l->peer[i];
    if (p->role != CLAUDE_ROLE_NONE) {
        return p->role == role;
    }
    if (role == CLAUDE_ROLE_MAC && conn == l->phone) {
        return false;   /* a Mac never holds the translator audio role */
    }
    if (role == CLAUDE_ROLE_RELAY && conn != l->phone) {
        return false;   /* the relay is the translator app itself */
    }
    for (int j = 0; j < CLAUDE_LINK_PEERS; j++) {
        if (j != i && l->peer[j].conn != CLAUDE_CONN_NONE && l->peer[j].role == role) {
            return false;
        }
    }
    p->role = role;
    return true;
}

bool claude_links_may_write(const claude_links_t *l, uint16_t conn)
{
    int i = claude_links_slot(l, conn);
    return i >= 0 && l->peer[i].answer;
}

claude_link_state_t claude_links_state(const claude_links_t *l, uint16_t voice_min_mtu)
{
    const claude_peer_t *mac = NULL, *relay = NULL;
    for (int i = 0; i < CLAUDE_LINK_PEERS; i++) {
        const claude_peer_t *p = &l->peer[i];
        if (p->conn == CLAUDE_CONN_NONE || !p->answer) {
            continue;
        }
        if (p->role == CLAUDE_ROLE_MAC) {
            mac = p;
        } else if (p->role == CLAUDE_ROLE_RELAY) {
            relay = p;
        }
    }
    const claude_peer_t *a = mac != NULL ? mac : relay;
    claude_link_state_t s = { .active = CLAUDE_CONN_NONE };
    if (a != NULL) {
        s.active = a->conn;
        s.relayed = a == relay;
        s.voice = a->voice && a->mtu >= voice_min_mtu;
        s.mtu = a->mtu;
    }
    return s;
}

size_t claude_link_events(claude_link_state_t was, claude_link_state_t now, claude_link_ev_t out[3])
{
    size_t n = 0;
    if (was.active != now.active) {
        if (was.active != CLAUDE_CONN_NONE) {
            out[n++] = CLAUDE_LINK_EV_DOWN;
        }
        if (now.active != CLAUDE_CONN_NONE) {
            out[n++] = CLAUDE_LINK_EV_UP;
            if (now.voice) {
                out[n++] = CLAUDE_LINK_EV_VOICE_ON;
            }
        }
    } else if (was.voice != now.voice) {
        out[n++] = now.voice ? CLAUDE_LINK_EV_VOICE_ON : CLAUDE_LINK_EV_VOICE_OFF;
    }
    return n;
}
```

Add `"claude_link.c"` to `firmware/main/CMakeLists.txt` after `"claude_proto.c"`.

- [ ] **Step 4: Run every host test**

Run:
```bash
cd firmware/test
cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_link test_claude_link.c ../main/claude_link.c && /tmp/test_claude_link
cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto
for f in test_*.c; do cmd=$(head -1 "$f" | sed 's/.*build: //'); (eval "$cmd") || echo "FAIL $f"; done
```
The loop runs every suite with the build line from its own first-line comment, so Phase 4's suites are included too. Expected: every suite prints its "all tests passed" line and there is no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add firmware/main/claude_link.h firmware/main/claude_link.c firmware/test/test_claude_link.c \
        firmware/main/claude_proto.h firmware/main/claude_proto.c firmware/test/test_claude_proto.c \
        firmware/main/CMakeLists.txt
git commit -m "firmware: Claude link roles from an explicit hello, Mac preferred over the iPhone relay (host-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---
### Task 7: Firmware: roles in `ble_link.c`, the active link, "via iPhone", and the on-device relay check (controller + user)

**Prerequisite:** Phase 4 is merged into this branch (it edits `ble_link.c` too). Locate every edit below by content.

**Files:**
- Modify: `firmware/main/ble_link.c`, `firmware/main/app.h` (`ble_link_claude_relayed`, comments), `firmware/main/claude_ui.c` (`refresh_status`)
- Modify: `firmware/test/claude_ble_test.py`, `firmware/test/claude_ble_phase2.py`, `firmware/test/claude_ble_voice.py` (send the "mac" hello)
- Create: `firmware/test/claude_ble_relay.py`

**Interfaces:**
- Consumes: `claude_link.h` and `claude_parse_hello` (Task 6). The Mac daemon from Task 5 (it says hello).
- Produces: `bool ble_link_claude_relayed(void);` (app.h). `ble_link_claude_connected`, `ble_link_send_claude_input*`, `ble_link_mac_mtu`, `ble_link_voice_ready`, `ble_link_voice_payload_max` and `ble_link_send_voice` keep their signatures and now act on the active Claude link (the Mac or the relay).

- [ ] **Step 1: Replace the single Mac slot with the link model**

In `firmware/main/ble_link.c`:

1. `#include "claude_link.h"` after `#include "claude_proto.h"`. After the `SVC_UUID` block, add:
   ```c
   _Static_assert(CLAUDE_CONN_NONE == BLE_HS_CONN_HANDLE_NONE, "claude_link.h must use NimBLE's no-connection value");
   ```
2. Replace the declarations of `s_voice_conn` (with its comment), `s_claude_rx` and `s_mac_conn` with:
   ```c
   /* Claude link roles per connection (claude_link.h): the Mac or the iPhone relay, from their hello. Host task only. */
   static claude_links_t s_links;
   static claude_link_state_t s_link_state = { .active = CLAUDE_CONN_NONE };
   /* One reassembly buffer per link slot: the Mac and the relay may both be writing (hellos) */
   static claude_rx_t s_claude_rx[CLAUDE_LINK_PEERS];
   /* Snapshots of s_link_state for the audio and LVGL tasks */
   static volatile uint16_t s_claude_conn = BLE_HS_CONN_HANDLE_NONE;
   static volatile bool s_claude_voice;
   static volatile bool s_claude_relayed;
   static volatile uint16_t s_claude_mtu;
   ```
   Keep `s_phone_conn`. Update the "Two links" comment: "Links: the iPhone (translator audio; also the Claude relay when the app relays) and the Mac (Claude, direct)".
3. Add, before `chr_access`:
   ```c
   /* Recomputes the active Claude link after any change and tells the app, in order (claude_link_events) */
   static void apply_links(void)
   {
       claude_link_state_t was = s_link_state;
       claude_link_state_t now = claude_links_state(&s_links, VOICE_MIN_MTU);
       s_link_state = now;
       s_claude_conn = now.active;
       s_claude_voice = now.voice;
       s_claude_relayed = now.relayed;
       s_claude_mtu = now.mtu;
       claude_link_ev_t ev[3];
       size_t n = claude_link_events(was, now, ev);
       for (size_t i = 0; i < n; i++) {
           switch (ev[i]) {
           case CLAUDE_LINK_EV_DOWN:
               ESP_LOGI(TAG, "Claude link down (%s)", was.relayed ? "iPhone relay" : "Mac");
               app_on_claude_link(false);   /* also ends voice (main.c) */
               break;
           case CLAUDE_LINK_EV_UP:
               ESP_LOGI(TAG, "Claude link up: %s (link %d, MTU %u)", now.relayed ? "via the iPhone relay" : "the Mac",
                        now.active, now.mtu);
               app_on_claude_link(true);
               break;
           case CLAUDE_LINK_EV_VOICE_ON:
               app_on_claude_voice_link(true);
               break;
           case CLAUDE_LINK_EV_VOICE_OFF:
               app_on_claude_voice_link(false);
               break;
           }
       }
   }
   ```
4. Replace the request-characteristic branch of `chr_access`:
   ```c
       } else if (attr_handle == s_claude_req_handle && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
           int slot = claude_links_slot(&s_links, conn_handle);
           if (slot < 0 || !claude_links_may_write(&s_links, conn_handle)) {
               return BLE_ATT_ERR_WRITE_NOT_PERMITTED;   /* subscribe to the answer characteristic first */
           }
           /* Static, not on the (6 KB) host task stack: access callbacks only run in the NimBLE host task */
           static uint8_t claude_buf[CLAUDE_WRITE_MAX];
           if (ble_hs_mbuf_to_flat(ctxt->om, claude_buf, sizeof(claude_buf), &len) != 0) {
               return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
           }
           static claude_msg_t msg;
           if (!claude_rx_feed(&s_claude_rx[slot], claude_buf, len, &msg)) {
               return 0;
           }
           if (msg.kind == CLAUDE_LINK) {
               int hello = claude_parse_hello(&msg);
               claude_role_t role = hello == CLAUDE_HELLO_MAC     ? CLAUDE_ROLE_MAC
                                    : hello == CLAUDE_HELLO_RELAY ? CLAUDE_ROLE_RELAY
                                                                  : CLAUDE_ROLE_NONE;
               if (claude_links_hello(&s_links, conn_handle, role)) {
                   ESP_LOGI(TAG, "link %d: Claude hello \"%.8s\"", conn_handle, msg.text);
                   apply_links();
               } else {
                   ESP_LOGW(TAG, "link %d: Claude hello \"%.8s\" refused", conn_handle, msg.text);
               }
               return 0;
           }
           if (conn_handle != s_link_state.active) {
               ESP_LOGW(TAG, "link %d: Claude message kind %d from an inactive link dropped", conn_handle, msg.kind);
               return 0;
           }
           app_on_claude_message(&msg);
           return 0;
       }
   ```
5. In `gap_event`:
   - `BLE_GAP_EVENT_DISCONNECT`: delete the `s_voice_conn` and `s_mac_conn` blocks. Inside the existing `s_phone_conn` block, after `app_on_connection_changed(false);`, add `claude_links_phone(&s_links, BLE_HS_CONN_HANDLE_NONE);`. Then, before `ancs_client_on_disconnect(...)`, add:
     ```c
             int slot = claude_links_slot(&s_links, event->disconnect.conn.conn_handle);
             if (slot >= 0) {
                 s_claude_rx[slot].len = 0;
             }
             claude_links_disconnected(&s_links, event->disconnect.conn.conn_handle);
             apply_links();   /* the Claude link went down, or moved to the other link */
     ```
   - audio subscription branch: right after the line `s_phone_conn = on ? event->subscribe.conn_handle : BLE_HS_CONN_HANDLE_NONE;` add `claude_links_phone(&s_links, s_phone_conn);`. After `app_on_connection_changed(on);` add `apply_links();` (losing the translator role drops the relay role).
   - replace the whole `s_claude_ans_handle` branch with:
     ```c
             } else if (event->subscribe.attr_handle == s_claude_ans_handle) {
                 uint16_t conn = event->subscribe.conn_handle;
                 bool on = event->subscribe.cur_notify;
                 if (!claude_links_answer(&s_links, conn, on)) {
                     ESP_LOGW(TAG, "link %d: no room for another Claude subscriber", conn);
                 }
                 if (!on) {
                     int slot = claude_links_slot(&s_links, conn);
                     if (slot >= 0) {
                         s_claude_rx[slot].len = 0;
                     }
                 }
                 ESP_LOGI(TAG, "link %d: Claude answers %s%s", conn, on ? "on" : "off",
                          event->subscribe.reason == BLE_GAP_SUBSCRIBE_REASON_RESTORE ? " (restored)" : "");
                 apply_links();   /* a role needs the hello that follows (kind 9) */
     ```
   - replace the whole `s_claude_voice_handle` branch with:
     ```c
             } else if (event->subscribe.attr_handle == s_claude_voice_handle) {
                 claude_links_voice(&s_links, event->subscribe.conn_handle, event->subscribe.cur_notify);
                 apply_links();   /* voice is live only on the active link with a full-frame MTU */
             }
     ```
   - `BLE_GAP_EVENT_MTU`: replace the `if (event->mtu.conn_handle == s_mac_conn …)` block with
     `claude_links_mtu(&s_links, event->mtu.conn_handle, event->mtu.value); apply_links();`
6. `ble_link_init`: call `claude_links_init(&s_links);` before `nimble_port_freertos_init(host_task);`.
7. Replace the Claude accessors at the end of the file:
   ```c
   bool ble_link_claude_connected(void)
   {
       return s_claude_conn != BLE_HS_CONN_HANDLE_NONE;
   }

   bool ble_link_claude_relayed(void)
   {
       return s_claude_conn != BLE_HS_CONN_HANDLE_NONE && s_claude_relayed;
   }
   ```
   In `send_claude_input`, use `uint16_t conn = s_claude_conn;`. In `ble_link_mac_mtu`, use `return s_claude_conn == BLE_HS_CONN_HANDLE_NONE ? 0 : s_claude_mtu;`. Then:
   ```c
   /* The active Claude link (Mac or relay) subscribed to voice and its MTU fits a full frame per notification */
   bool ble_link_voice_ready(void)
   {
       return s_claude_conn != BLE_HS_CONN_HANDLE_NONE && s_claude_voice;
   }

   uint16_t ble_link_voice_payload_max(void)
   {
       uint16_t mtu = s_claude_conn == BLE_HS_CONN_HANDLE_NONE ? 0 : s_claude_mtu;
       return mtu > 23 ? mtu - 3 : 20;
   }
   ```
   In `ble_link_send_voice`, replace the per-attempt check with
   `uint16_t conn = s_claude_conn; if (conn == BLE_HS_CONN_HANDLE_NONE || !s_claude_voice) { return false; }`.
8. Update the header comment of the Claude service block. Requests now come from "the Mac or the iPhone relay, after its hello (kind 9)". Answers and voice go to "the active Claude link (claude_link.h: the Mac, else the relay)".

In `firmware/main/app.h`, after `bool ble_link_claude_connected(void);`, add:
```c
/* The Claude link is the iPhone relay (the Mac is out of range), not the Mac itself */
bool ble_link_claude_relayed(void);
```
and change the `app_on_claude_link` comment to "Claude link (the Mac, or the iPhone relay) up/down".

In `firmware/main/claude_ui.c` `refresh_status`, replace the line that prints "Claude · Mac connected" with:
```c
        snprintf(status, sizeof(status), ble_link_claude_relayed() ? "Claude · via iPhone" : "Claude · Mac connected");
```
Also change the top-of-file comment line to `"Claude · Mac connected" / "Claude · via iPhone"`. `app_on_claude_link` runs on every switch and refreshes this status (`claude_ui_set_link`).

- [ ] **Step 2: Build**

Run: `. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && cd firmware && idf.py build 2>&1 | tail -3`
Expected: build succeeds with no new warnings. `grep -n "s_mac_conn\|s_voice_conn" firmware/main/ble_link.c` prints nothing.

- [ ] **Step 3: Fake-Mac scripts say hello; a fake relay script**

In each of `firmware/test/claude_ble_test.py`, `claude_ble_phase2.py` and `claude_ble_voice.py`, right after the `await c.start_notify(ANS, …)` line, add the following. Adjust the helper names to the script: `claude_ble_test.py` calls `message`/`chunks` directly, and the other two have the same helpers.

```python
        # Phase 5: the board gives this link the Mac role only after the hello (kind 9 "mac")
        for ch in chunks(message(9, 0, "mac"), c.mtu_size - 3):
            await c.write_gatt_char(REQ, ch, response=True)
```

Create `firmware/test/claude_ble_relay.py`:

```python
# firmware/test/claude_ble_relay.py — the board's relay path without the iPhone app (Phase 5).
# This Mac pretends to be the iPhone relay: it takes the translator audio role, says the "relay" hello and sends
# a permission request. Before running: stop the daemon (launchctl bootout gui/$(id -u)/dev.cicca.claude-board)
# and close the iPhone app or turn the iPhone's Bluetooth off (the board allows one translator role).
import asyncio, struct
from bleak import BleakScanner, BleakClient

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC, AUDIO = "a7c00001" + B, "a7c00002" + B
REQ, ANS = "a7c00011" + B, "a7c00012" + B

def message(kind, mid, text=""):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()

def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out

async def main():
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()

        async def send(kind, mid, text=""):
            for ch in chunks(message(kind, mid, text), c.mtu_size - 3):
                await c.write_gatt_char(REQ, ch, response=True)

        await c.start_notify(ANS, lambda _, d: inputs.put_nowait(bytes(d)))
        print("1. relay hello without the translator role: the monitor logs 'Claude hello \"relay\" refused'")
        await send(9, 0, "relay")
        await send(0, 1111, "relay-test\nBash\nmust not show")
        input("   The board shows no request, and the monitor logs 'from an inactive link dropped'. Enter to go on")

        print("2. take the translator role, then the relay hello")
        await c.start_notify(AUDIO, lambda _, d: None)
        await send(9, 0, "relay")
        input("   PWR x2: the Claude screen reads 'Claude · via iPhone'. Enter to go on")

        print("3. 'mac' on this (translator) link is refused: the monitor logs 'Claude hello \"mac\" refused'")
        await send(9, 0, "mac")

        print("4. a request over the relay: tap Allow on the board")
        await send(0, 4242, "relay-test\nBash\necho via the relay")
        while True:
            d = await asyncio.wait_for(inputs.get(), 90)
            mid, code = struct.unpack("<IB", d[:5])
            if mid == 4242:
                break
            print("   (board input", d.hex(), ")")
        print("   answer:", code)
        assert code == 1, "expected Allow"
        print("5. leaving: the board drops the relay link ('Claude · Mac not connected')")

asyncio.run(main())
```

- [ ] **Step 4: Flash and check on the device (controller + user)**

The controller runs the commands and asks the user to watch the board and answer the prompts:

```bash
cd mac && bash install.sh        # the Task 5 daemon (says hello); the pairing QR prints too. The user may scan later
. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && cd firmware && idf.py -p /dev/cu.usbmodem1101 flash monitor
```

| # | Check | Expected |
|---|---|---|
| 1 | Daemon running, board flashed, PWR ×2 | Monitor: `link N: Claude hello "mac"`, `Claude link up: the Mac`. Board: "Claude · Mac connected". Sessions appear as before |
| 2 | Trigger a permission request in a `cb` session and tap Allow | Works exactly as before (direct path) |
| 3 | Speak in the `cb` session | Voice works as before (voice is live on the Mac link) |
| 4 | `launchctl bootout gui/$(id -u)/dev.cicca.claude-board`; close the iPhone app (or the iPhone's Bluetooth); `python3 firmware/test/claude_ble_relay.py` | Steps 1–5 of the script behave as printed. "Claude · via iPhone" appears only after step 2 |
| 5 | `python3 firmware/test/claude_ble_test.py` (fake Mac with hello) | The request is shown and the answer is received |
| 6 | Restart the daemon (`bash mac/install.sh`) and reopen the iPhone app | Monitor: the iPhone link subscribes to audio and its restored answer CCCD (if any) gives it no role. "Claude · Mac connected" |

Record the results (and any deviation) in the task report. If row 6 shows a restored answer CCCD on the iPhone link, that is expected: no role without a hello.

- [ ] **Step 5: Commit**

```bash
git add firmware/main/ble_link.c firmware/main/app.h firmware/main/claude_ui.c firmware/test/claude_ble_test.py \
        firmware/test/claude_ble_phase2.py firmware/test/claude_ble_voice.py firmware/test/claude_ble_relay.py
git commit -m "firmware: the Claude link is the Mac or the iPhone relay (hello roles, active-link routing, via iPhone)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---

### Task 8: Shared: the iPhone relay state machine (`RelayBridge`, pure)

**Files:**
- Create: `relay/Sources/ClaudeRelay/RelayBridge.swift`, `relay/Tests/ClaudeRelayTests/RelayBridgeTests.swift`

**Interfaces:**
- Consumes: `RelayFrame`, `BLEFraming`, `BoardHello` (Task 1).
- Produces (used by Task 9):
  - `public struct VoiceAudioBuffer: Sendable { static let maxPackets = 1600; static func seq(_ packet: Data) -> UInt16?; mutating func append(_:); mutating func take() -> [Data]; var packets: [Data] }`
  - `public struct RelayBridge: Sendable { init(); var linked: Bool; mutating func handle(_ e: Event) -> [Action] }`
  - `RelayBridge.Event`: `macUp`, `macDown`, `boardUp(maxWrite: Int)`, `boardDown`, `boardSubscribed(Bool)`, `boardInput(Data)`, `boardVoice(Data)`, `mac(RelayFrame)`, `speech(String?)`, `transcript(UInt32, final: Bool, String)`, `transcriptFailed(UInt32, String)`
  - `RelayBridge.Action`: `subscribeBoard(Bool)`, `subscribeVoice(Bool)`, `writeBoard(Data)`, `toMac(RelayFrame)`, `transcribeBegin(UInt32)`, `transcribeFeed(Data)`, `transcribeFinish(UInt32)`, `transcribeCancel`

- [ ] **Step 1: Write the failing tests**

`relay/Tests/ClaudeRelayTests/RelayBridgeTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeRelay

/// A bridge with the Mac authenticated and the board's Claude service found (write size 20 + 1 flags byte)
private func linkedBridge(speech: String? = nil) -> RelayBridge {
    var b = RelayBridge()
    _ = b.handle(.speech(speech))
    _ = b.handle(.macUp)
    _ = b.handle(.boardUp(maxWrite: 21))
    _ = b.handle(.boardSubscribed(true))
    return b
}

private func packet(_ seq: UInt16) -> Data { Data([UInt8(seq & 0xff), UInt8(seq >> 8), 0, 0, 0, 0x11, 0x22]) }

@Test func noBoardSubscriptionWithoutTheMac() {
    var b = RelayBridge()
    #expect(b.handle(.boardUp(maxWrite: 185)).isEmpty)                 // no Mac: the board never sees a relay
    #expect(b.handle(.boardSubscribed(true)).isEmpty)
    #expect(b.handle(.boardInput(Data([9, 0, 0, 0, 0x32]))).isEmpty)
    #expect(!b.linked)
    #expect(b.handle(.macUp) == [.subscribeBoard(true)])
}

@Test func linkUpSaysHelloThenTellsTheMac() {
    var b = RelayBridge()
    _ = b.handle(.speech(nil))
    #expect(b.handle(.macUp).isEmpty)                                  // no board yet
    #expect(b.handle(.boardUp(maxWrite: 185)) == [.subscribeBoard(true)])
    let actions = b.handle(.boardSubscribed(true))
    #expect(actions == [.writeBoard(Data([0x03]) + BoardHello.relay), .toMac(.boardLink(true)),
                        .toMac(.voiceStatus(nil)), .subscribeVoice(true)])
    #expect(b.linked)
}

@Test func framesPassThroughUnchanged() {
    var b = linkedBridge()
    let message = Data([0]) + Data([4, 3, 2, 1]) + Data(String(repeating: "dự án ", count: 60).utf8.prefix(400))
    let writes = b.handle(.mac(.toBoard(message))).compactMap { if case .writeBoard(let d) = $0 { d } else { nil } }
    #expect(writes.count > 1 && writes.first!.first == 0x01 && writes.last!.first! & 0x02 != 0)
    #expect(writes.reduce(Data()) { $0 + $1.dropFirst() } == message)   // exactly the Mac's bytes
    #expect(b.handle(.boardInput(Data([4, 3, 2, 1, 1]))) == [.toMac(.fromBoard(Data([4, 3, 2, 1, 1])))])
    #expect(b.handle(.boardInput(Data([1, 2, 3]))).isEmpty)            // not a board input
    #expect(b.handle(.boardInput(Data(count: 11))).isEmpty)
}

@Test func macDownUnsubscribesAndBoardDownTellsTheMac() {
    var b = linkedBridge()
    #expect(b.handle(.boardSubscribed(false)) == [.toMac(.boardLink(false))])
    var c = linkedBridge()
    #expect(c.handle(.macDown) == [.subscribeBoard(false), .subscribeVoice(false)])
    #expect(c.handle(.mac(.toBoard(Data([2, 1, 0, 0, 0])))).isEmpty)
    var d = linkedBridge()
    #expect(d.handle(.boardDown) == [.toMac(.boardLink(false))])
    #expect(d.handle(.boardUp(maxWrite: 185)) == [.subscribeBoard(true)])
}

@Test func earlyAudioIsFedAtBegin() {
    var b = linkedBridge()
    for s: UInt16 in 0..<3 { #expect(b.handle(.boardVoice(packet(s))).isEmpty) }   // before the Mac's begin
    #expect(b.handle(.mac(.voiceBegin(7))) == [.transcribeBegin(7), .transcribeFeed(packet(0)),
                                                .transcribeFeed(packet(1)), .transcribeFeed(packet(2))])
    #expect(b.handle(.boardVoice(packet(3))) == [.transcribeFeed(packet(3))])
    #expect(b.handle(.mac(.voiceFinish(7))) == [.transcribeFinish(7)])
    #expect(b.handle(.boardVoice(packet(4))).isEmpty)                   // after finish: buffered, not fed
    #expect(b.handle(.transcript(7, final: false, "xin")) == [.toMac(.transcript(7, final: false, "xin"))])
    #expect(b.handle(.transcript(7, final: true, "Xin chào")) == [.toMac(.transcript(7, final: true, "Xin chào"))])
    #expect(b.handle(.transcript(7, final: true, "again")).isEmpty)    // the session is over
}

@Test func aNewCaptureStopsFeedingTheOldSession() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.boardVoice(packet(0))) == [.transcribeFeed(packet(0))])
    #expect(b.handle(.boardVoice(packet(1))) == [.transcribeFeed(packet(1))])
    // The board restarted (Say again) before the Mac's cancel arrived: seq 0 again
    #expect(b.handle(.boardVoice(packet(0))).isEmpty)
    #expect(b.handle(.boardVoice(packet(1))).isEmpty)
    #expect(b.handle(.mac(.voiceCancel(7))) == [.transcribeCancel])
    #expect(b.handle(.mac(.voiceBegin(8))) == [.transcribeBegin(8), .transcribeFeed(packet(0)), .transcribeFeed(packet(1))])
}

@Test func staleAndForeignVoiceTrafficIsIgnored() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.mac(.voiceFinish(6))).isEmpty)
    #expect(b.handle(.mac(.voiceCancel(6))).isEmpty)
    #expect(b.handle(.transcript(6, final: true, "old")).isEmpty)
    #expect(b.handle(.transcriptFailed(6, "old")).isEmpty)
    #expect(b.handle(.transcriptFailed(7, "Transcription did not start")) == [.toMac(.voiceFailed(7, "Transcription did not start"))])
    #expect(b.handle(.boardVoice(Data([0, 0]))).isEmpty)              // not an audio packet
}

@Test func beginWithoutSpeechFails() {
    var b = linkedBridge(speech: "Allow Speech Recognition for Live Translator on the iPhone")
    #expect(b.handle(.mac(.voiceBegin(3)))
            == [.toMac(.voiceFailed(3, "Allow Speech Recognition for Live Translator on the iPhone"))])
}

@Test func speechChangesReachTheMacAndTheVoiceSubscription() {
    var b = linkedBridge(speech: "not ready")
    #expect(b.handle(.speech(nil)) == [.toMac(.voiceStatus(nil)), .subscribeVoice(true)])
    #expect(b.handle(.speech("gone")) == [.toMac(.voiceStatus("gone")), .subscribeVoice(false)])
    var unlinked = RelayBridge()
    #expect(unlinked.handle(.speech(nil)).isEmpty)
}

@Test func linkLossCancelsTranscription() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    #expect(b.handle(.boardSubscribed(false)) == [.toMac(.boardLink(false)), .transcribeCancel])
}

@Test func longTranscriptsAreCut() {
    var b = linkedBridge()
    _ = b.handle(.mac(.voiceBegin(7)))
    let long = String(repeating: "chào ", count: 400)
    guard case .toMac(.transcript(7, true, let sent))? = b.handle(.transcript(7, final: true, long)).first else {
        Issue.record("no transcript"); return
    }
    #expect(sent.utf8.count <= RelayFrame.maxText && long.hasPrefix(sent))
}

@Test func audioBufferKeepsOneCapture() {
    var a = VoiceAudioBuffer()
    a.append(packet(0)); a.append(packet(1))
    a.append(packet(0))                                                  // a new capture
    #expect(a.packets == [packet(0)])
    for s in 1..<2000 { a.append(packet(UInt16(s))) }
    #expect(a.packets.count == VoiceAudioBuffer.maxPackets)
    #expect(a.take().count == VoiceAudioBuffer.maxPackets && a.packets.isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd relay && swift test 2>&1 | tail -3`
Expected: build errors (`cannot find 'RelayBridge'`).

- [ ] **Step 3: Implement**

`relay/Sources/ClaudeRelay/RelayBridge.swift`:

```swift
import Foundation

/// The board's voice audio (IMA ADPCM packets [seq u16][predictor i16][index u8][data]) from the current
/// capture's first packet (seq 0) until the Mac's voiceBegin. Only the latest capture is kept.
public struct VoiceAudioBuffer: Sendable {
    /// 32 s of 20 ms packets (a board capture stops at 30 s)
    public static let maxPackets = 1600
    public private(set) var packets: [Data] = []

    public init() {}

    public static func seq(_ packet: Data) -> UInt16? {
        guard packet.count >= 5 else { return nil }
        return UInt16(packet[packet.startIndex]) | UInt16(packet[packet.startIndex + 1]) << 8
    }

    public mutating func append(_ packet: Data) {
        guard let s = Self.seq(packet) else { return }
        if s == 0 { packets = [] }
        if packets.count < Self.maxPackets { packets.append(packet) }
    }

    public mutating func take() -> [Data] {
        defer { packets = [] }
        return packets
    }
}

/// The iPhone relay as a pure state machine: events from the Mac connection, the board's Claude service and the
/// phone's transcriber in, actions out. It never reads a board message. Board bytes go through unchanged (toBoard
/// is chunked like the Mac does, fromBoard is forwarded as notified). Its own words are the link hello, the board
/// link and voice status frames, and transcripts. The board subscription exists only while the Mac is reachable,
/// so the board falls back to "Mac not connected" instead of a relay that leads nowhere.
public struct RelayBridge: Sendable {
    public enum Event: Equatable, Sendable {
        case macUp, macDown
        /// The board's Claude characteristics were found (write size for chunks) / the board link went away
        case boardUp(maxWrite: Int), boardDown
        /// The answer subscription was confirmed (true) or ended
        case boardSubscribed(Bool)
        case boardInput(Data)
        case boardVoice(Data)
        case mac(RelayFrame)
        /// nil: the phone can transcribe the board's voice; else why not
        case speech(String?)
        case transcript(UInt32, final: Bool, String)
        case transcriptFailed(UInt32, String)
    }

    public enum Action: Equatable, Sendable {
        case subscribeBoard(Bool)
        case subscribeVoice(Bool)
        /// One chunk to the request characteristic, written with response, in order
        case writeBoard(Data)
        case toMac(RelayFrame)
        case transcribeBegin(UInt32)
        case transcribeFeed(Data)
        case transcribeFinish(UInt32)
        case transcribeCancel
    }

    private var macUp = false
    private var maxWrite: Int?
    private var wantSubscribed = false
    private var subscribed = false
    private var speech: String? = "Speech recognition is not ready on the iPhone"
    private var session: UInt32?
    private var sessionFed = 0
    private var sessionAudioOpen = false
    private var audio = VoiceAudioBuffer()

    public init() {}

    /// The phone holds the board's relay role and the Mac is reachable
    public var linked: Bool { macUp && maxWrite != nil && subscribed }

    public mutating func handle(_ e: Event) -> [Action] {
        var out: [Action] = []
        let wasLinked = linked
        switch e {
        case .macUp: macUp = true
        case .macDown: macUp = false
        case .boardUp(let m): maxWrite = max(20, m)
        case .boardDown:
            maxWrite = nil
            wantSubscribed = false
            subscribed = false
        case .boardSubscribed(let on): subscribed = on && wantSubscribed
        case .boardInput(let d):
            if linked, (5...RelayFrame.maxBoardInput).contains(d.count) { out.append(.toMac(.fromBoard(d))) }
        case .boardVoice(let p): voice(p, &out)
        case .mac(let f): mac(f, &out)
        case .speech(let why):
            speech = why
            if linked { out += [.toMac(.voiceStatus(why.map(Self.reason))), .subscribeVoice(why == nil)] }
        case .transcript(let s, let final, let text):
            guard s == session else { break }
            out.append(.toMac(.transcript(s, final: final, RelayFrame.fit(text, maxBytes: RelayFrame.maxText))))
            if final { endSession() }
        case .transcriptFailed(let s, let why):
            guard s == session else { break }
            out.append(.toMac(.voiceFailed(s, Self.reason(why))))
            endSession()
        }
        // The board subscription follows "Mac reachable and board present"
        let want = macUp && maxWrite != nil
        if maxWrite != nil && want != wantSubscribed {
            wantSubscribed = want
            if !want { subscribed = false }
            out.append(.subscribeBoard(want))
            if !want { out.append(.subscribeVoice(false)) }
        }
        if !wasLinked && linked, let m = maxWrite {
            out += BLEFraming.chunks(BoardHello.relay, maxChunk: m).map(Action.writeBoard)
            out += [.toMac(.boardLink(true)), .toMac(.voiceStatus(speech.map(Self.reason)))]
            if speech == nil { out.append(.subscribeVoice(true)) }
        } else if wasLinked && !linked {
            if macUp { out.append(.toMac(.boardLink(false))) }
            if session != nil {
                out.append(.transcribeCancel)
                endSession()
            }
        }
        return out
    }

    private mutating func mac(_ f: RelayFrame, _ out: inout [Action]) {
        switch f {
        case .toBoard(let d):
            guard linked, let m = maxWrite else { return }
            out += BLEFraming.chunks(d, maxChunk: m).map(Action.writeBoard)
        case .voiceBegin(let s):
            guard linked, speech == nil else {
                out.append(.toMac(.voiceFailed(s, Self.reason(speech ?? "The board is not connected to the iPhone"))))
                return
            }
            if session != nil { out.append(.transcribeCancel) }
            session = s
            sessionFed = 0
            sessionAudioOpen = true
            out.append(.transcribeBegin(s))
            for p in audio.take() {
                out.append(.transcribeFeed(p))
                sessionFed += 1
            }
        case .voiceFinish(let s):
            guard s == session else { return }
            sessionAudioOpen = false
            out.append(.transcribeFinish(s))
        case .voiceCancel(let s):
            guard s == session else { return }
            out.append(.transcribeCancel)
            endSession()
        default:
            break   // handshake frames stay in RelayClient
        }
    }

    private mutating func voice(_ p: Data, _ out: inout [Action]) {
        guard let seq = VoiceAudioBuffer.seq(p) else { return }
        let restarted = seq == 0 && sessionFed > 0
        if session != nil && sessionAudioOpen && !restarted {
            out.append(.transcribeFeed(p))
            sessionFed += 1
            return
        }
        if restarted { sessionAudioOpen = false }   // a new capture: the open session gets no more audio
        audio.append(p)
    }

    private mutating func endSession() {
        session = nil
        sessionFed = 0
        sessionAudioOpen = false
    }

    private static func reason(_ s: String) -> String {
        let r = RelayFrame.fit(s, maxBytes: RelayFrame.maxReason)
        return r.isEmpty ? "Speech recognition failed on the iPhone" : r
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd relay && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add relay/Sources/ClaudeRelay/RelayBridge.swift relay/Tests/ClaudeRelayTests/RelayBridgeTests.swift
git commit -m "relay: the iPhone relay state machine (opaque frames, hello, voice audio buffer, transcripts)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---
### Task 9: iPhone app: Claude service on the board link, pairing, Keychain, on-device transcription, the relay service

**Files:**
- Modify: `ios/project.yml`, `ios/ESPTranslator.xcodeproj/project.pbxproj` (regenerated), `ios/Sources/BLE/ESPLink.swift`, `ios/Sources/App/ConversationEngine.swift` (`link` no longer private), `ios/Sources/App/ESPTranslatorApp.swift`, `ios/Sources/UI/ContentView.swift`
- Create: `ios/Sources/Relay/RelayKeychain.swift`, `ios/Sources/Relay/BoardVoiceTranscriber.swift`, `ios/Sources/Relay/ClaudeRelayService.swift`, `ios/Sources/UI/RelayView.swift`

**Interfaces:**
- Consumes: `RelayBridge`, `RelayClient`, `RelayPairing`, `RelayFrame` (Tasks 1–3, 8); the board's Claude service (Task 7); the existing `ADPCMDecoder`, `BufferConverter`, `Diag`.
- Produces: the relay running inside the app. Nothing later consumes it in code; Task 10 tests it on device.
- Tests: the relay logic is covered by `relay/` tests (Tasks 1–3, 8). This task's gates are the iOS build, plus the `relay` and `mac` suites staying green. There is no iOS unit-test target (the repo has none; the pure parts live in the package on purpose).

- [ ] **Step 1: Package dependency and usage texts**

In `ios/project.yml`, add at top level (after `options:`):

```yaml
packages:
  ClaudeRelay:
    path: ../relay
```

and in the `ESPTranslator` target add `dependencies: [{ package: ClaudeRelay }]`. Also add these `info.properties`:

```yaml
        NSCameraUsageDescription: Scans the pairing QR code that claude-board prints on your Mac.
        NSLocalNetworkUsageDescription: Reaches your Mac over Tailscale to relay Claude Code requests to the board.
```

Run: `cd ios && xcodegen generate`
Expected: "Created project at …/ESPTranslator.xcodeproj".

- [ ] **Step 2: The board's Claude service in `ESPLink`**

In `ios/Sources/BLE/ESPLink.swift`:

```swift
    static let claudeService = CBUUID(string: "A7C00010-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeRequest = CBUUID(string: "A7C00011-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeAnswer = CBUUID(string: "A7C00012-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
    static let claudeVoice = CBUUID(string: "A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A")

    /// Claude relay (all on the BLE queue): the write size once the Claude characteristics are found, nil when the
    /// board link is gone; the answer subscription state; board inputs; board voice audio (ADPCM)
    var onClaudeReady: (@Sendable (Int?) -> Void)?
    var onClaudeSubscribed: (@Sendable (Bool) -> Void)?
    var onClaudeInput: (@Sendable (Data) -> Void)?
    var onClaudeVoice: (@Sendable (Data) -> Void)?

    private var claudeRequestChar: CBCharacteristic?
    private var claudeAnswerChar: CBCharacteristic?
    private var claudeVoiceChar: CBCharacteristic?
    private var answerRetried = false

    /// The board's Claude answers (and with them the relay role, after the hello). Encrypted: the board is bonded.
    func setClaudeSubscribed(_ on: Bool) {
        queue.async { [self] in
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

    /// One relay chunk ([flags][payload]), with response so none is dropped or reordered
    func writeClaude(_ chunk: Data) {
        queue.async { [self] in
            guard let peripheral, let c = claudeRequestChar else { return }
            peripheral.writeValue(chunk, for: c, type: .withResponse)
        }
    }
```

Changes in the delegate code:
- `didConnect`: `peripheral.discoverServices([Self.service, Self.claudeService])`.
- `didDiscoverServices`: loop over `peripheral.services ?? []`. For `Self.service`, discover the three translator characteristics as today. For `Self.claudeService`, call `peripheral.discoverCharacteristics([Self.claudeRequest, Self.claudeAnswer, Self.claudeVoice], for: s)`.
- `didDiscoverCharacteristicsFor`: when `service.uuid == Self.claudeService`, store the three characteristics. If request and answer exist, call `onClaudeReady?(peripheral.maximumWriteValueLength(for: .withoutResponse))` and return. The translator branch (the existing body) runs only for `Self.service`.
- `didDisconnectPeripheral`: nil the three Claude characteristics and call `onClaudeReady?(nil)`.
- `didUpdateValueFor`: `claudeAnswer` → `onClaudeInput?(value)`; `claudeVoice` → `onClaudeVoice?(value)`.
- new:

```swift
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
                    guard self.peripheral === peripheral, peripheral.state == .connected else { return }
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
```

Update the class comment ("protocol: see firmware/main/ble_link.c") to mention that the Claude service is used only by the relay (`ClaudeRelayService`).

- [ ] **Step 3: Keychain**

`ios/Sources/Relay/RelayKeychain.swift`:

```swift
import ClaudeRelay
import Foundation
import Security

/// The Mac pairing (host, port, secret) as its claudeboard:// URL in the Keychain, this device only, readable
/// after the first unlock (the relay runs in the background). Never in UserDefaults.
enum RelayKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.cicca.esptranslator.relay",
        kSecAttrAccount as String: "mac",
    ]

    static func load() -> RelayPairing? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return RelayPairing.parse(text)   // re-validated on every load
    }

    @discardableResult
    static func save(_ pairing: RelayPairing) -> Bool {
        forget()
        var item = base
        item[kSecValueData as String] = Data(pairing.url.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget() { SecItemDelete(base as CFDictionary) }
}
```

- [ ] **Step 4: Transcribing the board's voice on the iPhone**

`ios/Sources/Relay/BoardVoiceTranscriber.swift`:

```swift
import AVFAudio
import Foundation
import Speech

/// On-device Vietnamese dictation of the board's voice capture while it is relayed (same model and options as the
/// Mac's SpeechEngine: mac/Sources/claude-board/SpeechEngine.swift). One analyzer per capture; the model stays
/// loaded. Not thread-safe: VoiceWorker calls it from one task, in order.
final class BoardVoiceTranscriber: @unchecked Sendable {
    private let locale = Locale(identifier: "vi-VN")
    private static let boardFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                                   interleaved: true)!
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, Never>?
    private var decoder = ADPCMDecoder()
    private var converter: BufferConverter?

    private func makeModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// nil when ready; else why not (sent to the Mac, which shows it on the board)
    func prepare() async -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return "Allow Speech Recognition for Live Translator on the iPhone"
        case .notDetermined:
            let s = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            if s != .authorized { return "Allow Speech Recognition for Live Translator on the iPhone" }
        default:
            break
        }
        guard await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return "Vietnamese dictation is not available on this iPhone"
        }
        do {
            if try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) != nil {
                return "Open Live Translator once to install the Vietnamese speech model"
            }
        } catch {
            return "Speech model check failed on the iPhone"
        }
        return nil
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws {
        await cancel()
        let module = makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CocoaError(.featureUnsupported)
        }
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let results = Task<String, Never> {
            var finals: [String] = []
            var volatile = ""
            func joined() -> String { (finals + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ") }
            do {
                for try await r in module.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.isFinal {
                        if !text.isEmpty { finals.append(text) }
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onPartial(joined())
                }
            } catch {}
            return joined()
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        self.analyzer = analyzer
        self.input = input
        self.results = results
        decoder.reset()
        converter = BufferConverter(target: format)
    }

    func feed(_ packet: Data) {
        guard let input, let converter else { return }
        let samples = decoder.decode(packet)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.boardFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async -> String {
        guard let analyzer, let input, let results else { return "" }
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = await results.value
        clear()
        return text
    }

    func cancel() async {
        input?.finish()
        results?.cancel()
        await analyzer?.cancelAndFinishNow()
        clear()
    }

    private func clear() {
        analyzer = nil
        input = nil
        results = nil
        converter = nil
    }
}

/// Runs the transcriber's commands strictly in order on one task (begin is async; packets arrive meanwhile)
final class VoiceWorker: @unchecked Sendable {
    enum Command: Sendable { case begin(UInt32), feed(Data), finish(UInt32), cancel }
    enum Event: Sendable { case partial(UInt32, String), final(UInt32, String), failed(UInt32, String) }

    var onEvent: (@Sendable (Event) -> Void)?
    private let transcriber = BoardVoiceTranscriber()
    private let commands: AsyncStream<Command>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        let transcriber = self.transcriber
        Task { [weak self] in
            var session: UInt32?
            for await command in stream {
                switch command {
                case .begin(let s):
                    do {
                        try await transcriber.begin { text in self?.onEvent?(.partial(s, text)) }
                        session = s
                    } catch {
                        session = nil
                        self?.onEvent?(.failed(s, "Transcription did not start on the iPhone"))
                    }
                case .feed(let p):
                    if session != nil { transcriber.feed(p) }
                case .finish(let s):
                    guard session == s else { continue }
                    let text = await transcriber.finish()
                    session = nil
                    self?.onEvent?(.final(s, text))
                case .cancel:
                    session = nil
                    await transcriber.cancel()
                }
            }
        }
    }

    func send(_ command: Command) { commands.yield(command) }
    func prepare() async -> String? { await transcriber.prepare() }
}
```

- [ ] **Step 5: The relay service**

`ios/Sources/Relay/ClaudeRelayService.swift`:

```swift
import ClaudeRelay
import Foundation
import Network

/// Relays the board's Claude messages to the paired Mac and back (RelayBridge decides; this performs).
/// The WebSocket is open only while the app is paired and the board's Claude service is connected (battery). Failed
/// connections retry with backoff (5 s doubling to 5 min) and once at each network change. No other polling.
/// All state lives on `queue`.
final class ClaudeRelayService: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case notPaired, waitingForBoard, connecting, relayReady, failed(String)
    }

    var onStatus: (@Sendable (Status, String?) -> Void)?   // status, paired host

    private let link: ESPLink
    private let queue = DispatchQueue(label: "relay.service")
    private var bridge = RelayBridge()
    private var pairing: RelayPairing?
    private var client: RelayClient?
    private var boardUp = false
    private var macUp = false
    private var lastError: String?
    private var retryDelay: TimeInterval = 5
    private var retryGeneration = 0
    private var lastPartial = Date.distantPast
    private let monitor = NWPathMonitor()
    private let voice = VoiceWorker()

    init(link: ESPLink) {
        self.link = link
        link.onClaudeReady = { [weak self] max in self?.queue.async { self?.boardReady(max) } }
        link.onClaudeSubscribed = { [weak self] on in self?.queue.async { self?.handle(.boardSubscribed(on)) } }
        link.onClaudeInput = { [weak self] d in self?.queue.async { self?.handle(.boardInput(d)) } }
        link.onClaudeVoice = { [weak self] p in self?.queue.async { self?.handle(.boardVoice(p)) } }
        voice.onEvent = { [weak self] e in self?.queue.async { self?.voiceEvent(e) } }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            self?.queue.async { self?.retryNow() }
        }
        monitor.start(queue: queue)
        queue.async { [self] in
            pairing = RelayKeychain.load()
            publish()
        }
        Task { [weak self, voice] in
            let why = await voice.prepare()
            self?.queue.async { self?.handle(.speech(why)) }
        }
    }

    func pair(_ p: RelayPairing) {
        queue.async { [self] in
            RelayKeychain.save(p)
            pairing = p
            dropClient()
            retryDelay = 5
            lastError = nil
            connectIfNeeded()
            publish()
        }
    }

    func forget() {
        queue.async { [self] in
            RelayKeychain.forget()
            pairing = nil
            dropClient()
            lastError = nil
            publish()
        }
    }

    private func boardReady(_ max: Int?) {
        boardUp = max != nil
        handle(max.map { .boardUp(maxWrite: $0) } ?? .boardDown)
        if boardUp { connectIfNeeded() } else { dropClient() }   // no board, no WebSocket
        publish()
    }

    private func connectIfNeeded() {
        guard let pairing, boardUp, client == nil else { return }
        let c = RelayClient(pairing: pairing)
        c.onState = { [weak self, weak c] s in self?.queue.async { if let c { self?.clientState(s, c) } } }
        c.onFrame = { [weak self] f in self?.queue.async { self?.handle(.mac(f)) } }
        client = c
        c.connect()
    }

    private func dropClient() {
        retryGeneration += 1
        client?.disconnect()
        client = nil
        if macUp {
            macUp = false
            handle(.macDown)
        }
    }

    private func clientState(_ s: RelayClient.State, _ c: RelayClient) {
        guard c === client else { return }
        switch s {
        case .authenticated:
            macUp = true
            retryDelay = 5
            lastError = nil
            handle(.macUp)
        case .failed(let why):
            Diag.log("relay: \(why)")
            lastError = why
            client = nil
            if macUp {
                macUp = false
                handle(.macDown)
            }
            scheduleRetry()
        case .idle, .connecting:
            break
        }
        publish()
    }

    private func scheduleRetry() {
        retryGeneration += 1
        let gen = retryGeneration
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.retryGeneration else { return }
            self.connectIfNeeded()
        }
    }

    private func retryNow() {
        guard client == nil, pairing != nil, boardUp else { return }
        retryGeneration += 1
        connectIfNeeded()
    }

    private func handle(_ e: RelayBridge.Event) {
        for action in bridge.handle(e) { perform(action) }
        publish()
    }

    private func perform(_ a: RelayBridge.Action) {
        switch a {
        case .subscribeBoard(let on): link.setClaudeSubscribed(on)
        case .subscribeVoice(let on): link.setClaudeVoice(on)
        case .writeBoard(let chunk): link.writeClaude(chunk)
        case .toMac(let f): client?.send(f)
        case .transcribeBegin(let s):
            lastPartial = .distantPast
            voice.send(.begin(s))
        case .transcribeFeed(let p): voice.send(.feed(p))
        case .transcribeFinish(let s): voice.send(.finish(s))
        case .transcribeCancel: voice.send(.cancel)
        }
    }

    private func voiceEvent(_ e: VoiceWorker.Event) {
        switch e {
        case .partial(let s, let text):
            let now = Date()
            guard now.timeIntervalSince(lastPartial) >= 0.25 else { return }   // at most 4 partials a second
            lastPartial = now
            handle(.transcript(s, final: false, text))
        case .final(let s, let text): handle(.transcript(s, final: true, text))
        case .failed(let s, let why): handle(.transcriptFailed(s, why))
        }
    }

    private func publish() {
        let status: Status =
            pairing == nil ? .notPaired
            : !boardUp ? .waitingForBoard
            : macUp && bridge.linked ? .relayReady
            : lastError.map(Status.failed) ?? .connecting
        onStatus?(status, pairing?.host)
    }
}
```

- [ ] **Step 6: The relay screen with the QR scanner**

`ios/Sources/UI/RelayView.swift`:

```swift
import AVFoundation
import ClaudeRelay
import Observation
import SwiftUI

@MainActor
@Observable
final class RelayModel {
    private(set) var status: ClaudeRelayService.Status = .notPaired
    private(set) var host: String?
    @ObservationIgnored private let service: ClaudeRelayService

    init(link: ESPLink) {
        service = ClaudeRelayService(link: link)
        service.onStatus = { [weak self] status, host in
            Task { @MainActor in
                self?.status = status
                self?.host = host
            }
        }
    }

    var paired: Bool { host != nil }

    var statusText: String {
        switch status {
        case .notPaired: "Not paired with a Mac"
        case .waitingForBoard: "Paired with \(host ?? "your Mac"). Waiting for the board"
        case .connecting: "Connecting to \(host ?? "your Mac") over Tailscale…"
        case .relayReady: "Relay ready: the board reaches \(host ?? "your Mac") through this iPhone when the Mac is out of range"
        case .failed(let why): "Not connected: \(why)"
        }
    }

    func pair(_ p: RelayPairing) { service.pair(p) }
    func forget() { service.forget() }
}

struct RelayView: View {
    let model: RelayModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") { Text(model.statusText) }
                Section {
                    Button(model.paired ? "Pair again" : "Pair with Mac", systemImage: "qrcode.viewfinder") { scanning = true }
                    if model.paired {
                        Button("Forget this Mac", systemImage: "trash", role: .destructive) { model.forget() }
                    }
                } footer: {
                    Text("""
                    On the Mac, run mac/install.sh (or ~/.claude-board/bin/claude-board --pair) and scan the QR code \
                    it prints. Both devices need Tailscale on the same tailnet. Requests are never answered here: \
                    the iPhone only passes them between the board and the Mac.
                    """)
                }
            }
            .navigationTitle("Claude relay")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    scanning = false
                    if let p = RelayPairing.parse(code) {
                        model.pair(p)
                    } else {
                        scanError = "That is not a claude-board pairing code for a Tailscale address."
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Can't pair", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
                Button("OK") { scanError = nil }
            } message: {
                Text(scanError ?? "")
            }
        }
    }
}

/// Camera QR scanner (AVFoundation); calls `found` once with the first QR code's text
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.showDenied() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.layer.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        private func showDenied() {
            let label = UILabel()
            label.text = "Allow the camera for Live Translator in Settings to scan the pairing code."
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 24, dy: 24)
            view.addSubview(label)
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            session.stopRunning()
            found?(code)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }
    }
}
```

- [ ] **Step 7: Wire it into the app**

- `ios/Sources/App/ConversationEngine.swift`: change `private let link = ESPLink()` to `let link = ESPLink()   // shared with the Claude relay (RelayModel)`.
- `ios/Sources/App/ESPTranslatorApp.swift`:

```swift
import SwiftUI

@main
struct ESPTranslatorApp: App {
    @State private var engine: ConversationEngine
    @State private var relay: RelayModel

    init() {
        let engine = ConversationEngine()
        _engine = State(initialValue: engine)
        _relay = State(initialValue: RelayModel(link: engine.link))   // starts relaying if a Mac is paired
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine, relay: relay)
                .task { await engine.start() }
        }
    }
}
```

- `ios/Sources/UI/ContentView.swift`: add `let relay: RelayModel` and `@State private var showRelay = false`. Add a leading toolbar item:

```swift
                ToolbarItem(placement: .topBarLeading) {
                    Button("Claude relay", systemImage: "point.3.connected.trianglepath.dotted") { showRelay = true }
                }
```

and `.sheet(isPresented: $showRelay) { RelayView(model: relay) }` on the `NavigationStack`. Fix any `#Preview` or other `ContentView(engine:)` call sites so they pass a `RelayModel(link: ESPLink())`.

- [ ] **Step 8: Build everything**

Run:
```bash
cd ios && xcodegen generate && xcodebuild -project ESPTranslator.xcodeproj -scheme ESPTranslator \
  -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error|BUILD" | tail -20
cd ../relay && swift test 2>&1 | tail -2
cd ../mac && swift test 2>&1 | tail -2
```
Expected: `** BUILD SUCCEEDED **` with no errors, and both suites pass. If the first package resolution exceeds 4 minutes, run it once with `-resolvePackageDependencies` and then build.

- [ ] **Step 9: Commit**

```bash
git add ios/project.yml ios/ESPTranslator.xcodeproj/project.pbxproj ios/Sources/BLE/ESPLink.swift \
        ios/Sources/App/ConversationEngine.swift ios/Sources/App/ESPTranslatorApp.swift ios/Sources/UI/ContentView.swift \
        ios/Sources/Relay/RelayKeychain.swift ios/Sources/Relay/BoardVoiceTranscriber.swift \
        ios/Sources/Relay/ClaudeRelayService.swift ios/Sources/UI/RelayView.swift
git commit -m "ios: Claude relay (QR pairing into the Keychain, board Claude service, on-device voice transcription)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

(Also stage `ios/ESPTranslator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` if XcodeGen or Xcode created it.)

---

### Task 10: README and end-to-end acceptance with the Mac out of range (controller + user)

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above, installed: the daemon (`bash mac/install.sh`), the firmware (Task 7), and the iPhone app (built and run from Xcode on the user's iPhone).

- [ ] **Step 1: README**

1. In the Architecture or Repository layout section, add `relay/` (the shared Swift package used by the daemon and the iPhone app).
2. Add a subsection **"Away from the Mac (iPhone relay)"** after the Claude companion's "Safety rules". It covers:
   - What it does. When the Mac is out of Bluetooth range, the board's Claude screen reads "Claude · via iPhone" and everything keeps working through the iPhone app: requests, questions, sessions, voice (transcribed on the iPhone). When the Mac is back in range, the board and the daemon switch back to the direct link by themselves. A request that is on the board at the moment of a switch falls through to the terminal, as on any disconnect.
   - Setup (yours, once). Install Tailscale on the Mac and the iPhone and sign both in to the same tailnet (the plan installs nothing). Then run `bash mac/install.sh`, or `~/.claude-board/bin/claude-board --pair` if Tailscale came later. In the iPhone app: Claude relay → Pair with Mac → scan the code. If the macOS firewall is on, allow incoming connections for `claude-board`.
   - Security. The daemon listens only on its Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48 on a utun interface), port 47821. It never listens on Wi-Fi/LAN, loopback or the internet, and it re-checks the address when the network changes. The secret lives in `~/.claude-board/relay.secret` (0600, refused otherwise) and in the iPhone Keychain. The connection does a mutual HMAC-SHA256 challenge-response: the secret never crosses the network, and a replayed exchange fails. After 5 failed attempts in a minute the daemon refuses connections for a minute. The iPhone never answers anything: it passes the board's messages through unchanged, and every id check applies on both ends. Nothing is ever auto-approved. `claude-board --pair --new-secret` rotates the secret (then restart the daemon and scan again). `mac/uninstall.sh` deletes it.
   - Battery. The app keeps one WebSocket open only while it is paired and the board is connected. It pings every 60 s; there is no other polling. Traffic flows only for requests, session updates and voice.
   - Limits. The iPhone app must be running (it already runs in the background for the translator). Free developer accounts must reinstall the app every 7 days. Voice through the relay uses the iPhone's speech model (Vietnamese).
   - Logs. The daemon logs `iPhone relay listening on 100.x…`, `relay: iPhone authenticated`, `board path: relay` / `direct`. The board monitor logs `Claude link up: via the iPhone relay`.
3. Add a **"Relay protocol"** subsection with the hello and relay frame tables from this plan's Protocol section. Add the kind 9 row to the Claude message list wherever the README lists message kinds.
4. In "Known limitations", add: "The relay needs Tailscale on both devices and the iPhone app running."

- [ ] **Step 2: End-to-end with the user (Mac out of BLE range)**

Preparation (controller): `bash mac/install.sh` (prints the QR code to the user's terminal; the controller does not copy it anywhere). Check that the firmware from Task 7 is flashed. The user builds and runs the iPhone app from Xcode. Then go through the table with the user and record each result:

| # | Action | Expected |
|---|---|---|
| 1 | In the app: Claude relay → Pair with Mac → scan | Status "Relay ready…". Daemon log: `relay: iPhone authenticated (100.…)`, `relay: board link up on the iPhone` |
| 2 | Board near the Mac, PWR ×2 | "Claude · Mac connected"; daemon log `board path: direct` |
| 3 | Turn the Mac's Bluetooth off (Control Center), or carry the board and iPhone out of range | Within ~10 s: "Claude · via iPhone"; daemon log `board path: relay`; the session rows reappear |
| 4 | Trigger a permission request in a `cb` session, tap Allow (then another: Deny) | The board shows it with the chime. Claude continues or is denied exactly as on the direct link |
| 5 | Trigger an AskUserQuestion with two questions; answer on the board | Claude receives the chosen labels |
| 6 | Speak on the Claude screen (focused `cb` session), say a short command, Send | The partial transcript is live, then the final. The command is typed into the pane once. Daemon log: voice over the relay |
| 7 | Speak and say nothing | "Didn't catch that"; nothing typed |
| 8 | Mac Bluetooth back on, board near the Mac | Within ~10 s: "Claude · Mac connected", `board path: direct`; a request goes direct |
| 9 | Kill the iPhone app while on the relay | The board shows "Mac not connected"; a request falls through to the terminal prompt (nothing answered) |
| 10 | `lsof -nP -iTCP:47821 -sTCP:LISTEN` on the Mac | Exactly one listener, on the 100.x (or fd7a:) address |
| 11 | From another device on the LAN: `nc -vz <Mac LAN IP> 47821` | Connection refused |
| 12 | `claude-board --pair --new-secret`, restart the daemon, do not rescan | App status "Not connected: Pairing check failed…"; daemon log `handshake … rejected`; rescanning fixes it |
| 13 | Leave the relay idle 10 minutes (Mac out of range, no Claude activity) | No repeated reconnect lines in the daemon log; the app stays "Relay ready" |

If a row fails, fix it (with a regression test in the owning task's suite where possible), rerun the row, and note it in the report.

- [ ] **Step 3: Record and commit**

Add the verification line under the README's relay section (date, Claude Code version, rows passed). Then:

```bash
git add README.md
git commit -m "README: away from the Mac (iPhone relay over Tailscale): setup, security, protocol, verified on hardware

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm"
```

---

## Spec coverage (self-review)

| Spec / decision | Task |
|---|---|
| Daemon listens on its Tailscale address only; refuses other interfaces | 2 (address rules), 3 (bound listener, remote check), 5 (watcher, host lifecycle) |
| Shared secret generated at install, 0600 | 2 (`RelaySecretFile`, `--pair`, install.sh) |
| Installer prints a QR (address + port + secret); app scans once; Keychain | 2 (QR), 9 (scanner, `RelayKeychain`) |
| WebSocket carrying the same message frames; authenticated, replay-protected HMAC handshake | 1 (frames, handshake), 3 (server/client) |
| iPhone relays opaque frames, never interprets or answers | 8 (`RelayBridge`), 9 (performs only) |
| Board prefers direct Mac link, else relay (security: encrypted + bonded, role checks, ids) | 6 (model), 7 (ble_link) |
| Daemon prefers direct BLE, else relay | 4 (`BoardRouter`), 5 (wiring) |
| Voice away from the Mac: iPhone transcribes, text only (frame defined) | 1 (transcript frames), 4 (`RelayVoiceEngine`), 8 (audio buffer), 9 (transcriber) |
| Never auto-approve; all id checks apply | unchanged `RequestQueue` / `VoiceHub` paths; 4 (router feeds the same handlers) |
| Port never exposed to the internet; tests without Tailscale | 2, 3 (loopback policy), 5 |
| Battery: no polling, keepalive ≥ 30 s, traffic only on events | 3 (ping 60 s, TCP keepalive), 8/9 (WebSocket only with board + pairing) |
| Free account 7-day reinstall; Tailscale is the user's job | 10 (README) |
| End-to-end with the Mac out of range | 10 |
