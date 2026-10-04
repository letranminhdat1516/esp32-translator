# Phase 3: Voice Commands Near the Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speak a command on the board's Claude screen (or an "Other" answer to a question, or a reason for a denial), see the live transcript, confirm it with an explicit Send, and have the Mac daemon type it into the focused Claude Code session's tmux pane (or apply it as the answer / denial reason), started by a `cb` launcher that runs `claude` inside a marked tmux pane.

**Architecture:** The board streams its mic as IMA ADPCM (the existing `audio_in.c` encoder, 16 kHz) on a new encrypted notify characteristic of the Claude service, only between a voice *start* and *stop* input; the translator stream to the iPhone pauses meanwhile, and all encoding/sending stays in the audio task. The Mac daemon gains a `VoiceHub` actor that decodes the audio, feeds an on-device `SpeechAnalyzer` (`DictationTranscriber`, `vi_VN`) and sends partial and final transcripts back as a new message kind; the final transcript is already sanitised (`VoiceText.forTyping`) so the board shows exactly what Send would type. Send types into the session's tmux pane (`send-keys -l`, then one Enter) only after `TmuxTyper` re-verifies the pane (marked `@claude_board` by `cb`, pane process in the hook's recorded ancestor chain, alive, not in copy mode); for "Other" and "Deny with reason" the text goes into the pending request instead. Pure logic is host-tested on both sides (`voice.c` endpointing + confirm flow, `VoiceText`, `ADPCMDecoder`, `TmuxTyper` with a fake runner and against a real tmux server, `VoiceHub` with a fake engine and typer).

**Tech Stack:** Swift 6 package with Swift Testing (`mac/`), Speech framework `SpeechAnalyzer`/`DictationTranscriber` and AVFAudio (macOS 26, `@available`-gated, package floor stays macOS 14), tmux ≥ 3.0 (Homebrew), bash (`cb`), Python 3 standard library (installer helpers + unittest), ESP-IDF 5.5, FreeRTOS, LVGL 9.6 (esp_lvgl_adapter), NimBLE; host C tests compiled with `cc`; `bleak` for the on-device fake-Mac script.

**Spec:** `docs/superpowers/specs/2026-10-04-board-modes-claude-sessions-design.md` (section "Phase 3: voice commands (near the Mac)", plus Phase 2's "**Other 🎤** (Phase 3)" and "Voice is also used for **Other** answers and **Deny with reason**"), plus the decisions agreed in conversation (copied into Global Constraints below; binding). Phase 2 plan for conventions and the existing protocol: `docs/superpowers/plans/2026-10-04-phase2-claude-sessions.md`. Carried from the Phase 2 ledger (`.superpowers/sdd/2026-10-04-phase2-claude-sessions/progress.md`): "Phase 3 must verify the focused session's tmux pane still belongs to that session before typing"; "NimBLE host stack 6144 with headroom ~2.7 KB measured — audio must not be encoded/sent from the host task".

## Global Constraints

- Spec (verbatim): "Claude screen 🎤: tap to start, auto-stop after ~1.5 s silence or tap again. The level ring tracks the voice; partial transcript is shown live." "Audio: board mic → ADPCM over the Mac BLE link, only while recording; translation streaming to the iPhone pauses meanwhile." "The Mac transcribes on device (SpeechAnalyzer, Vietnamese by default)." "Confirmation is mandatory: transcript with **Say again / Cancel / Send**." "Send → the daemon types the text into the focused session's tmux pane (`send-keys -l`, control characters stripped, one Enter at the end). If Claude is working, the text queues like typed input." "Voice is also used for **Other** answers and **Deny with reason**." "`cb` launcher: starts `claude` (with any arguments) inside a tmux session named after the project; Remote Control works as usual. Sessions without a tmux pane show a disabled 🎤 with "Open with `cb` for voice"." "Errors: no Mac link → 🎤 hidden; empty transcript → "Didn't catch that, say again"; tmux failure → error shown, nothing sent."
- Audio path (agreed): board mic → IMA ADPCM 16 kHz mono (reuse `adpcm_encode`, same packet header `[seq u16][predictor i16][index u8]` as the iPhone audio) → new characteristic `A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A` "Claude voice" (notify, encrypted: `BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC`) on the Claude service. Packets flow only between a voice start and its stop/cancel. The translator stream to the iPhone sends nothing meanwhile and resumes afterwards with a fresh VAD state (no half phrase).
- Endpointing (agreed): capture ends after 1.5 s of silence following speech (`VOICE_SILENCE_FRAMES 75`), 5 s with no speech at all (`VOICE_NOTHING_FRAMES 250`, the Mac then returns an empty transcript), 30 s total (`VOICE_MAX_FRAMES 1500`), a Stop tap, or the Mac voice link going away.
- Transcription (agreed): on the Mac, on device, `DictationTranscriber` with locale `VoiceConfig.localeIdentifier = "vi_VN"` (a single constant; `en_US` is a later toggle, not built now); `AssetInventory` installs the model if missing; partial transcripts go to the board at most every 250 ms.
- Confirmation (agreed): mandatory screen with the final transcript and **Say again / Cancel / Send** (for an Other answer the confirm button reads **Use**: it fills the question page's Other row, and the answers still go only with the page's own **Send**). The final transcript the board shows is byte-for-byte what Send types or answers (`VoiceText.forTyping`, done on the Mac before the final message).
- Typed text (agreed): `VoiceText.forTyping`: control characters, U+2028/U+2029 → spaces; bidi controls (U+200E, U+200F, U+202A–U+202E, U+2066–U+2069) removed; typographic quotes ‘ ’ “ ” → ' and "; whitespace runs → one space; trimmed; leading `!`, `/`, `#` removed (Claude Code's bash, slash-command and memory modes); at most `VoiceText.maxBytes = 300` UTF-8 bytes cut at a Character boundary without "…" (firmware `CLAUDE_VOICE_TEXT_MAX 300`).
- tmux typing (agreed): `tmux -S <socket> send-keys -t <pane> -l -- <text>` (a trailing `;` is sent as `\;`, see Task 2), then 200 ms, then `tmux -S <socket> send-keys -t <pane> Enter`. The socket is `$TMUX` up to its first comma, forwarded by the hook; it must be a socket owned by the user. Before typing (and already at voice start, for an early error) the pane must exist, not be dead, carry the pane option `@claude_board` = `1` (set by `cb`), not be in a mode (copy mode), and its `pane_pid` must be in the ancestor chain the hook recorded for that session (if it is not the hook's direct parent, the chain member just below it must still be its child). Any failure: error shown on the board, nothing typed.
- `cb` (agreed): installed by `mac/install.sh` into `~/.claude-board/bin/cb`, symlinked to `~/.local/bin/cb` only when `~/.local/bin` exists and holds no other `cb`; outside tmux it runs `claude "$@"` in a new tmux session named after the current directory (`.` and `:` and other characters outside `[A-Za-z0-9_-]` become `_`), or attaches to that session if it exists; inside tmux it marks the current pane and execs `claude "$@"`.
- Availability (agreed): no Mac voice link (voice characteristic not subscribed) → no Speak button, no Other row, no "Deny + why"; focused session without a voice-capable pane (session flag bit 2 clear) → Speak disabled with "Open with cb for voice"; empty transcript → "Didn't catch that" + "Say again, or Cancel." with Send hidden; a voice-capable flag but an unmarked pane → the Mac answers the start with the error "Open with cb for voice".
- Safety (spec + agreed): nothing is auto-approved; voice text is never typed, stored as an answer or used as a denial without an explicit armed, lit tap on Send / Use for that exact voice id; the Mac refuses to type while the session "needs you" (a terminal prompt could take the keystrokes as its answer) or has ended; never type into a pane that cannot be verified.
- Answer controls: the existing 700 ms arming (`ARM_DELAY_US`) and dark-panel rejection apply to every voice control (Speak, Stop, Say again, Cancel, Send / Use, Deny + why, the Other row). Showing the confirm screen re-arms (a tap on Stop never lands on Send).
- Battery (spec + agreed): zero cost unless recording: the codec opens only while a capture or the translator needs it; the voice characteristic carries nothing outside a capture; Mac → board voice messages only answer a capture; the overlay's timers exist only while it is shown.
- NimBLE host task (Phase 2 ledger): it only parses voice messages (static buffers) and updates labels under the display lock; it never encodes or sends audio. Stack stays 6144.
- macOS: Speech code is `@available(macOS 26.0, *)` in the daemon target only; `mac/Package.swift` keeps `.macOS(.v14)`; the embedded `Info.plist` gains `NSSpeechRecognitionUsageDescription` (no microphone key: audio comes over BLE).
- Board UI text is English and uses only `font_vi_22` / `font_vi_36` (ASCII + Vietnamese + `·` `…` `—`; no emoji: the 🎤 button reads "Speak", the Other row "Other (speak)").
- LVGL threading (Phase 1, unchanged): calls from non-LVGL tasks only between `bsp_display_lock((uint32_t)-1)` and `bsp_display_unlock()`; never take that lock inside LVGL event callbacks or `lv_timer` callbacks. Functions named `*_locked` expect the lock held. Never delete an object from inside its own event callback.
- Do not touch `ios/`.
- Commands: Mac `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test`; installer tests `cd mac && python3 -m unittest test_claude_settings test_cb -v`; host C tests `cd firmware/test && cc -Wall -Wextra -Werror -I../main -o /tmp/<name> <name>.c ../main/<module>.c [...] && /tmp/<name>`; firmware `. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && cd firmware && idf.py build` (flash: `idf.py -p /dev/cu.usbmodem1101 flash monitor`).
- Every commit message ends with exactly these two lines (after a blank line):
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
  ```

## Review Focus

1. **Typing into the wrong place**: Claude exited and a plain shell is left in the pane, the pane id now belongs to another program, the pane is in copy mode, the session shows a terminal permission prompt ("needs you"), the tmux server is someone else's socket: nothing is typed and the board shows why (Task 2 tests `shellLeftInThePaneIsRefused`, `paneOfAnotherProcessIsRefused`, `copyModeIsRefused`, `foreignSocketIsRefused`, `realTmuxTypesOnlyIntoAMarkedPane`; Task 4 test `needsYouIsNeverTypedInto`).
2. **Text that tmux or Claude Code would misread**: a leading `-`, a trailing `;` or `\;`, braces, a leading `!` / `/` / `#`, newlines, tabs, bidi controls, curly quotes, more than 300 bytes of Vietnamese: the pane receives exactly the confirmed text and one Enter (Task 1 test `forTypingCleansAndCaps`; Task 2 tests `trailingSemicolonIsEscaped`, `realTmuxTypesOnlyIntoAMarkedPane`).
3. **Stale or out-of-order voice traffic**: Send for an old voice id after Say again, Send before the final transcript, cancel while finishing, a second start while one runs, audio after stop, a Mac update for a capture the board already left: ignored on both sides (Task 4 tests `staleVoiceIdsAreIgnored`, `sendBeforeTheFinalIsIgnored`, `cancelWhileFinishingDropsTheText`; Task 7 test `stale_updates_are_ignored`).
4. **The request goes away during an Other / Deny capture** (answered in the terminal, timed out, replaced): the board cancels the capture, and the Mac refuses to store an Other answer or deny for a request that is not the one shown (Task 3 tests `setOtherOnlyForTheShownQuestion`, `denyWithReasonOnlyForTheShownPermission`; Task 4 test `otherForAGoneQuestionFails`; Task 9 on-device row 5).
5. **Silence, noise or a mumble**: nothing said for 5 s, a single click, or a transcript that sanitises to nothing: "Didn't catch that", Send hidden on the board and refused on the Mac (Task 1 test `forTypingCleansAndCaps` (only `!//#` → ""); Task 4 test `emptyTranscriptIsNeverTyped`; Task 7 tests `vad_click_is_not_speech`, `empty_final_cannot_be_sent`).

---

## File structure

```
mac/Sources/ClaudeBoardCore/
  BoardInput.swift       MOD  VoicePurpose; voiceStart / voiceStop / voiceCancel / voiceSend
  BoardMessage.swift     MOD  kind 8 .voice(id:, VoiceUpdate)
  Sessions.swift         MOD  SessionRow.voice (flags bit 2); VoiceTarget
  Utf8.swift             MOD  fitTail
  VoiceText.swift        NEW  forTyping (sanitise + cap)
  ADPCMDecoder.swift     NEW  IMA ADPCM packets → 16 kHz Int16 (port of the iOS decoder)
  TmuxTyper.swift        NEW  PaneTarget, TmuxSocket, PaneCheck, ProcessTree, PaneTyping, TmuxTyper
  HookEnvelope.swift     MOD  hook ancestor chain (claude_board_pids)
  HookEvent.swift        MOD  hookAncestors
  SessionTracker.swift   MOD  pane target per session, voice flag, voiceTarget(handle:)
  SessionHub.swift       MOD  voiceTarget(handle:); BoardInput voice cases ignored
  RequestQueue.swift     MOD  Other answers (bit 7), deny with reason, shownShape
  AnswerMapping.swift    MOD  Other text in answers, deny reason reply
  HookProcessor.swift    MOD  answers carry the Other texts
  VoiceHub.swift         NEW  VoiceConfig, VoiceEngine/VoiceStream protocols, the capture state machine
mac/Sources/claude-board/
  SpeechEngine.swift     NEW  DictationTranscriber engine, PCM converter, --transcribe self-test
  BoardLink.swift        MOD  voice characteristic subscription, onVoiceAudio
  main.swift             MOD  VoiceHub wiring, --transcribe
  Info.plist             MOD  NSSpeechRecognitionUsageDescription
mac/Sources/claude-board-hook/main.swift   MOD  forwards the ancestor chain
mac/cb                                     NEW  tmux launcher
mac/claude_settings.py                     MOD  link-cb / unlink-cb
mac/install.sh, mac/uninstall.sh           MOD  install cb (+ symlink)
mac/test_cb.py                             NEW
mac/test_claude_settings.py                MOD  link-cb tests
mac/Tests/ClaudeBoardCoreTests/
  VoiceProtocolTests.swift NEW   TmuxTyperTests.swift NEW   VoiceHubTests.swift NEW
  HookEnvelopeTests.swift, SessionTrackerTests.swift, RequestQueueTests.swift, AnswerMappingTests.swift,
  HookProcessorTests.swift, SocketProtocolTests.swift (SIGPIPE in fake daemons)  MOD

firmware/main/
  claude_proto.h / .c    MOD  kind 8 parser, voice input encoders, session VOICE flag
  voice.h / voice.c      NEW  endpointing VAD + confirm flow (pure)
  voice_ui.c             NEW  voice overlay on the Claude screen
  audio_in.c             REWRITE  translator stream + voice capture to the Mac
  ble_link.c             MOD  Claude voice characteristic
  claude_ui.c            MOD  Speak, Deny + why, tap_armed, voice routing
  question.h / .c        MOD  Other answer (bit 7, text per page)
  sessions.c             MOD  focusing keeps the voice flag
  question_ui.c          MOD  Other row
  ui.c                   MOD  panel stays on while the overlay is shown
  main.c                 MOD  kind 8 dispatch, voice link
  app.h                  MOD  declarations
  CMakeLists.txt         MOD  voice.c, voice_ui.c
firmware/test/
  test_claude_proto.c MOD   test_voice.c NEW   test_question.c MOD   test_sessions.c MOD
  claude_ble_voice.py NEW   fake Mac for the on-device voice checks
README.md                MOD  voice commands, cb, protocol
```

## Protocol (both sides implement exactly this)

New characteristic `A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A` "Claude voice" (board → Mac, notify, encrypted): `[seq u16 LE][predictor i16 LE][index u8][IMA ADPCM 4-bit, low nibble first]`, 16 kHz mono, exactly like the iPhone audio characteristic; each packet carries its own ADPCM state; `seq` restarts at 0 for every capture. Sent only between a voice start and its stop / cancel.

Mac → board, request characteristic `…0011` (unchanged envelope), new kind:

| kind | name | id | text |
|---|---|---|---|
| 8 | voice | voice id (≠ 0) | `"<w>\n<text>"`: `p` partial (live; the Mac keeps the end and prefixes "…" when it is longer than 398 bytes), `f` final (exactly what Send would type, ≤ 300 bytes, may be empty), `x` error (the capture is over; text is the reason), `k` done (after Send: typed, answer stored or denied; text is a short result line) |

Session rows (kind 4): flags bit 2 (`4`) = **voice**: the session reported a tmux pane, a tmux socket and a hook ancestor chain (the pane itself is verified only when a capture starts and again on Send). `CLAUDE_SESSION_VOICE 0x04`; flags now range 0…7.

Board → Mac, answer characteristic `…0012` (notify, ≤ 10 bytes):

| bytes | meaning |
|---|---|
| `[voice u32 LE][0x30][purpose u8][target u32 LE]` | capture starts. purpose low nibble: 0 command (target = session handle; high nibble 0), 1 Other answer (target = question request id; high nibble = question index 0…3), 2 deny with reason (target = permission request id; high nibble 0). voice and target never 0 |
| `[voice u32 LE][0x31]` | stop: the audio is complete (sent by the audio task after its last packet) |
| `[voice u32 LE][0x32]` | cancel: drop this capture |
| `[voice u32 LE][0x33]` | send: type / store / deny with this capture's final transcript |
| `[id u32 LE][0x10][n u8][mask × n]` | question answers (unchanged), plus: bit 7 of mask q = the spoken Other answer of question q (stored on the Mac by a send for purpose 1) |

Shared test vectors (asserted in Swift and in C): start Other: voice `0x0A0B0C0D`, question 2, target `0x01020304` → `0d 0c 0b 0a 30 21 04 03 02 01`; start command: voice 9, target 5 → `09 00 00 00 30 00 05 00 00 00`; stop / cancel / send voice 9 → `09 00 00 00 31` / `…32` / `…33`; final `"Xin chào"` for voice 9 → `08 09 00 00 00` + `"f\nXin chào"`; session row with focused + voice → `04 05 00 00 00` + `"w 1759555200 1759555260 5\ndự-án\nDone."`; answers with Other on page 0: id `0x01020304`, masks `[0x80, 0x05]` → `04 03 02 01 10 02 80 05`; ADPCM packet `00 00 00 00 00 07` decodes to samples `[11, 13]`.

---

### Task 1: Mac — voice wire format, typed-text rules and the ADPCM decoder (pure)

**Files:**
- Modify: `mac/Sources/ClaudeBoardCore/BoardInput.swift` (whole file), `mac/Sources/ClaudeBoardCore/BoardMessage.swift` (kind 8), `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift` (`tag(_:)` switch), `mac/Sources/ClaudeBoardCore/Sessions.swift` (voice flag), `mac/Sources/ClaudeBoardCore/Utf8.swift` (`fitTail`), `mac/Sources/ClaudeBoardCore/RequestQueue.swift:101-106` and `mac/Sources/ClaudeBoardCore/SessionHub.swift:79-80` (exhaustive switches), `mac/Sources/claude-board/main.swift:16-24` (exhaustive switch)
- Create: `mac/Sources/ClaudeBoardCore/VoiceText.swift`, `mac/Sources/ClaudeBoardCore/ADPCMDecoder.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/VoiceProtocolTests.swift`

**Interfaces:**
- Consumes: `AskQuestion.maxQuestions` (4), `Utf8.fit`, `Utf8.oneLine`, `BoardMessage.textMax` (400).
- Produces (used by Tasks 2–5):
  - `public enum VoicePurpose: Equatable, Sendable { case command; case other(question: Int); case denyReason }`
  - `BoardInput` cases `.voiceStart(voice: UInt32, purpose: VoicePurpose, target: UInt32)`, `.voiceStop(voice: UInt32)`, `.voiceCancel(voice: UInt32)`, `.voiceSend(voice: UInt32)`
  - `public enum VoiceUpdate: Equatable, Sendable { case partial(String), final(String), error(String), done(String) }`, `BoardMessage.voice(id: UInt32, VoiceUpdate)` (kind 8)
  - `SessionRow.voice: Bool` (init parameter `voice: Bool = false`, last), `flags` bit 2
  - `Utf8.fitTail(_ s: String, maxBytes: Int) -> String`
  - `VoiceText.maxBytes = 300`, `VoiceText.forTyping(_ raw: String) -> String`
  - `public struct ADPCMDecoder { public init(); public mutating func decode(_ packet: Data) -> [Int16]; public mutating func reset() }`

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/VoiceProtocolTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

@Test func voiceInputsDecodeTheSharedVectors() {
    #expect(BoardInput.decode(Data([0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01]))
            == .voiceStart(voice: 0x0A0B0C0D, purpose: .other(question: 2), target: 0x01020304))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0])) == .voiceStart(voice: 9, purpose: .command, target: 5))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x30, 0x02, 7, 0, 0, 0])) == .voiceStart(voice: 9, purpose: .denyReason, target: 7))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x31])) == .voiceStop(voice: 9))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x32])) == .voiceCancel(voice: 9))
    #expect(BoardInput.decode(Data([9, 0, 0, 0, 0x33])) == .voiceSend(voice: 9))
    // Other answers ride on the unchanged answers input (bit 7)
    #expect(BoardInput.decode(Data([0x04, 0x03, 0x02, 0x01, 0x10, 2, 0x80, 0x05])) == .answers(id: 0x01020304, masks: [0x80, 0x05]))
}

@Test func voiceInputsRejectBadShapes() {
    let bad: [[UInt8]] = [
        [0, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0],      // voice id 0
        [9, 0, 0, 0, 0x30, 0x00, 0, 0, 0, 0],      // target 0
        [9, 0, 0, 0, 0x30, 0x03, 5, 0, 0, 0],      // unknown purpose
        [9, 0, 0, 0, 0x30, 0x10, 5, 0, 0, 0],      // command with a question index
        [9, 0, 0, 0, 0x30, 0x12, 5, 0, 0, 0],      // deny reason with a question index
        [9, 0, 0, 0, 0x30, 0x41, 5, 0, 0, 0],      // Other for question 4 (max 4 questions: 0...3)
        [9, 0, 0, 0, 0x30, 0x00, 5, 0, 0],         // short
        [9, 0, 0, 0, 0x31, 0],                     // stop with a trailing byte
        [0, 0, 0, 0, 0x33],                        // send for voice 0
    ]
    for b in bad { #expect(BoardInput.decode(Data(b)) == nil, "\(b)") }
}

@Test func voiceMessageEncodesKind8() {
    let final = BoardMessage.voice(id: 9, .final("Xin chào")).encode()
    #expect(final == Data([8, 9, 0, 0, 0]) + Data("f\nXin chào".utf8))
    #expect(BoardMessage.voice(id: 9, .partial("a")).encode() == Data([8, 9, 0, 0, 0]) + Data("p\na".utf8))
    #expect(BoardMessage.voice(id: 9, .error("No\npane")).encode() == Data([8, 9, 0, 0, 0]) + Data("x\nNo pane".utf8))
    #expect(BoardMessage.voice(id: 9, .done("Sent")).encode() == Data([8, 9, 0, 0, 0]) + Data("k\nSent".utf8))
    #expect(BoardMessage.voice(id: 9, .final("")).encode() == Data([8, 9, 0, 0, 0]) + Data("f\n".utf8))
}

@Test func longPartialKeepsItsEnd() {
    let words = (1...200).map { "từ\($0)" }.joined(separator: " ")
    let d = BoardMessage.voice(id: 1, .partial(words)).encode()
    let text = String(decoding: d.dropFirst(5), as: UTF8.self)
    #expect(d.count - 5 <= BoardMessage.textMax)
    #expect(text.hasPrefix("p\n…") && text.hasSuffix("từ200"))
}

@Test func fitTailKeepsWholeCharactersAtTheEnd() {
    #expect(Utf8.fitTail("abc", maxBytes: 3) == "abc")
    #expect(Utf8.fitTail("abcdef", maxBytes: 5) == "…ef")
    #expect(Utf8.fitTail("xin chào", maxBytes: 7) == "…hào")     // "…" (3) + "hào" (4: "à" is 2 bytes)
    #expect(Utf8.fitTail("abcdef", maxBytes: 2) == "")
}

@Test func sessionRowCarriesTheVoiceFlag() {
    let r = SessionRow(handle: 5, state: .working, since: 1_759_555_200, updated: 1_759_555_260,
                       focused: true, unseen: false, project: "dự-án", lastLine: "Done.", voice: true)
    #expect(r.flags == 5)
    #expect(BoardMessage.session(r).encode() == Data([4, 5, 0, 0, 0]) + Data("w 1759555200 1759555260 5\ndự-án\nDone.".utf8))
    let plain = SessionRow(handle: 5, state: .idle, since: 1, updated: 2, focused: false, unseen: true,
                           project: "p", lastLine: "")
    #expect(!plain.voice && plain.flags == 2)
}

@Test func forTypingCleansAndCaps() {
    #expect(VoiceText.forTyping("  chạy\tcác bài\r\nkiểm tra  ") == "chạy các bài kiểm tra")
    #expect(VoiceText.forTyping("!rm -rf /") == "rm -rf /")                  // never bash mode
    #expect(VoiceText.forTyping("/clear") == "clear")                        // never a slash command
    #expect(VoiceText.forTyping(" # note") == "note")                        // never memory mode
    #expect(VoiceText.forTyping("! / #") == "")                              // nothing left: never typed
    #expect(VoiceText.forTyping("“Chạy” ‘test’") == "\"Chạy\" 'test'")
    #expect(VoiceText.forTyping("a\u{202E}b\u{2066}c\u{200F}") == "abc")     // bidi controls dropped
    #expect(VoiceText.forTyping("a\u{2028}b\u{0}c") == "a b c")
    #expect(VoiceText.forTyping("-x {a} ok;") == "-x {a} ok;")               // tmux escaping is Task 2's job
    let long = String(repeating: "ữ", count: 150)                            // 450 bytes
    let capped = VoiceText.forTyping(long)
    #expect(capped.utf8.count == 300 && capped == String(repeating: "ữ", count: 100))
    let spaced = String(repeating: "ab ", count: 120)                        // the cut lands after a space
    #expect(!VoiceText.forTyping(spaced).hasSuffix(" ") && VoiceText.forTyping(spaced).utf8.count <= 300)
}

@Test func adpcmDecodesTheSharedVector() {
    var d = ADPCMDecoder()
    #expect(d.decode(Data([0, 0, 0, 0, 0, 0x07])) == [11, 13])
}

@Test func adpcmFillsSmallGapsWithSilence() {
    var d = ADPCMDecoder()
    _ = d.decode(Data([0, 0, 0, 0, 0, 0x07]))
    let next = d.decode(Data([3, 0, 0, 0, 0, 0x07]))          // seq 1 and 2 lost: 2 packets × 2 samples of silence
    #expect(next == [0, 0, 0, 0, 11, 13])
    d.reset()
    #expect(d.decode(Data([9, 0, 0, 0, 0, 0x07])) == [11, 13])   // after reset: no gap fill
    #expect(d.decode(Data([1, 2, 3])) == [])                     // shorter than a header: nothing
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter VoiceProtocolTests 2>&1 | tail -20`
Expected: build errors (`type 'BoardInput' has no member 'voiceStart'`, `cannot find 'VoiceText' in scope`, `cannot find 'ADPCMDecoder' in scope`, …).

- [ ] **Step 3: Board inputs**

Replace the whole of `mac/Sources/ClaudeBoardCore/BoardInput.swift` with:

```swift
import Foundation

public enum BoardChoice: UInt8, Sendable { case allow = 1, deny = 2, alwaysAllow = 3 }

/// What the board shows, as it reports it: session traffic flows only for .claude and .picker.
public enum BoardMode: UInt8, Sendable { case other = 0, claude = 1, picker = 2 }

/// What a voice capture is for. Wire: purpose byte, low nibble 0 / 1 / 2, high nibble the question index (Other only).
public enum VoicePurpose: Equatable, Sendable {
    /// Typed into the session's tmux pane; target = session handle
    case command
    /// The spoken "Other" answer to question `question` of the AskUserQuestion on the board; target = request id
    case other(question: Int)
    /// Deny the permission request on the board with the spoken reason; target = request id
    case denyReason
}

/// Board → Mac on the answer characteristic. Request answers carry the request id (never 0); id 0 marks
/// board events; voice inputs carry the voice id (never 0).
///   [id u32 LE][1|2|3]                      allow / deny / always allow
///   [id u32 LE][0x10][n u8][mask × n]       question answers, bit i of mask q = option i, bit 7 = Other text
///   [0 u32][0x20][mode u8]                  board mode
///   [0 u32][0x21][handle u32 LE]            focus this session
///   [voice u32][0x30][purpose u8][target u32 LE]   voice capture starts
///   [voice u32][0x31] / [0x32] / [0x33]     audio complete / cancel / send the final transcript
public enum BoardInput: Equatable, Sendable {
    case choice(id: UInt32, BoardChoice)
    case answers(id: UInt32, masks: [UInt8])
    case mode(BoardMode)
    case focus(handle: UInt32)
    case voiceStart(voice: UInt32, purpose: VoicePurpose, target: UInt32)
    case voiceStop(voice: UInt32)
    case voiceCancel(voice: UInt32)
    case voiceSend(voice: UInt32)

    public static func decode(_ d: Data) -> BoardInput? {
        let b = [UInt8](d)
        guard b.count >= 5 else { return nil }
        let id = le32(b, 0)
        switch (id == 0, b[4]) {
        case (false, 1...3):
            guard b.count == 5, let c = BoardChoice(rawValue: b[4]) else { return nil }
            return .choice(id: id, c)
        case (false, 0x10):
            guard b.count >= 6 else { return nil }
            let n = Int(b[5])
            guard (1...AskQuestion.maxQuestions).contains(n), b.count == 6 + n else { return nil }
            return .answers(id: id, masks: Array(b[6...]))
        case (true, 0x20):
            guard b.count == 6, let m = BoardMode(rawValue: b[5]) else { return nil }
            return .mode(m)
        case (true, 0x21):
            guard b.count == 9 else { return nil }
            let h = le32(b, 5)
            return h == 0 ? nil : .focus(handle: h)
        case (false, 0x30):
            guard b.count == 10 else { return nil }
            let target = le32(b, 6)
            guard target != 0, let purpose = voicePurpose(b[5]) else { return nil }
            return .voiceStart(voice: id, purpose: purpose, target: target)
        case (false, 0x31):
            return b.count == 5 ? .voiceStop(voice: id) : nil
        case (false, 0x32):
            return b.count == 5 ? .voiceCancel(voice: id) : nil
        case (false, 0x33):
            return b.count == 5 ? .voiceSend(voice: id) : nil
        default:
            return nil
        }
    }

    private static func voicePurpose(_ byte: UInt8) -> VoicePurpose? {
        let question = Int(byte >> 4)
        switch byte & 0x0f {
        case 0: return question == 0 ? .command : nil
        case 1: return question < AskQuestion.maxQuestions ? .other(question: question) : nil
        case 2: return question == 0 ? .denyReason : nil
        default: return nil
        }
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
```

The new cases make three existing switches non-exhaustive. In `mac/Sources/ClaudeBoardCore/RequestQueue.swift`, `handle(_:)`, replace `case .mode, .focus: return` with `case .mode, .focus, .voiceStart, .voiceStop, .voiceCancel, .voiceSend: return`. In `mac/Sources/ClaudeBoardCore/SessionHub.swift`, `boardInput(_:)`, replace `case .choice, .answers:` with `case .choice, .answers, .voiceStart, .voiceStop, .voiceCancel, .voiceSend:`. In `mac/Sources/claude-board/main.swift`, in `board.onInput`, add after the `case .mode, .focus:` branch (Task 5 wires it to the voice hub):

```swift
    case .voiceStart, .voiceStop, .voiceCancel, .voiceSend:
        break
```

- [ ] **Step 4: Kind 8, the voice flag and `fitTail`**

In `mac/Sources/ClaudeBoardCore/BoardMessage.swift`:

Add before `public enum BoardMessage`:

```swift
/// Mac → board about one voice capture (message kind 8, id = voice id).
public enum VoiceUpdate: Equatable, Sendable {
    /// Live transcript while recording (the board shows the end of it)
    case partial(String)
    /// Exactly what Send would type or answer (VoiceText.forTyping); "" = nothing heard
    case final(String)
    /// The capture is over; shown to the user
    case error(String)
    /// Send succeeded (typed, answer stored, or denied)
    case done(String)
}
```

Add the case after `case question(…)`:

```swift
    /// One voice capture's transcript or result (kind 8, id = the board's voice id)
    case voice(id: UInt32, VoiceUpdate)
```

The test helper `tag(_:)` in `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift` switches over every `BoardMessage`: add `case .voice(let id, _): "voice\(id)"` after its `.question` line.

In the doc comment of `encode()`, append `, 8 voice (id = voice id, "<p|f|x|k>\ntext")` before the closing period. In the `switch self` of `encode()`, add after the `.question` line:

```swift
        case .voice(let id, let u): (8, id, Self.voiceText(u))
```

Add after `questionText(…)`:

```swift
    private static func voiceText(_ u: VoiceUpdate) -> String {
        let room = textMax - 2   // "<w>\n"
        switch u {
        case .partial(let s): return "p\n" + Utf8.fitTail(Utf8.oneLine(s), maxBytes: room)
        case .final(let s): return "f\n" + Utf8.fit(Utf8.oneLine(s), maxBytes: room)
        case .error(let s): return "x\n" + Utf8.fit(Utf8.oneLine(s), maxBytes: room)
        case .done(let s): return "k\n" + Utf8.fit(Utf8.oneLine(s), maxBytes: room)
        }
    }
```

In `mac/Sources/ClaudeBoardCore/Sessions.swift`, add the stored property after `public var lastLine: String`:

```swift
    /// The session runs in a tmux pane its hooks reported (pane + socket + ancestry): voice commands can target it
    public var voice: Bool
```

change the initializer to

```swift
    public init(handle: UInt32, state: SessionState, since: Int64, updated: Int64, focused: Bool, unseen: Bool,
                project: String, lastLine: String, voice: Bool = false) {
        self.handle = handle
        self.state = state
        self.since = since
        self.updated = updated
        self.focused = focused
        self.unseen = unseen
        self.project = project
        self.lastLine = lastLine
        self.voice = voice
    }
```

and `flags` to

```swift
    /// Wire flags: bit0 focused, bit1 unseen, bit2 voice
    public var flags: Int { (focused ? 1 : 0) | (unseen ? 2 : 0) | (voice ? 4 : 0) }
```

In `mac/Sources/ClaudeBoardCore/Utf8.swift`, add after `fit(_:maxBytes:)`:

```swift
    /// `s` if it fits; else "…" plus the longest suffix of whole Characters within `maxBytes` (live transcripts:
    /// the newest words matter); "" when not even the ellipsis fits.
    public static func fitTail(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes >= 3 else { return "" }
        var kept: [Character] = []
        var used = 0
        for ch in s.reversed() {
            let n = ch.utf8.count
            if used + n > maxBytes - 3 { break }
            kept.append(ch)
            used += n
        }
        return "…" + String(kept.reversed())
    }
```

- [ ] **Step 5: `VoiceText` and `ADPCMDecoder`**

Create `mac/Sources/ClaudeBoardCore/VoiceText.swift`:

```swift
import Foundation

/// The rules for text that voice puts into a Claude Code session. The board shows the result of `forTyping`
/// before the user confirms, so what they read is exactly what is typed (or answered).
public enum VoiceText {
    /// Firmware CLAUDE_VOICE_TEXT_MAX
    public static let maxBytes = 300

    /// Control characters and line/paragraph separators become spaces, bidi controls are dropped, typographic
    /// quotes become ASCII (the board fonts have no curly quotes), whitespace runs collapse, the text is trimmed,
    /// leading "!", "/" and "#" are removed (Claude Code's bash, slash-command and memory modes), and the result
    /// is cut to `maxBytes` at a Character boundary without an ellipsis.
    public static func forTyping(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.value {
            case 0x2018, 0x2019: scalars.append("'")
            case 0x201C, 0x201D: scalars.append("\"")
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: continue
            default:
                let control = u.properties.generalCategory == .control || u.value == 0x2028 || u.value == 0x2029
                scalars.append(control ? " " : u)
            }
        }
        var s = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let c = s.first, c == "!" || c == "/" || c == "#" || c == " " { s.removeFirst() }
        return cap(s)
    }

    static func cap(_ s: String) -> String {
        if s.utf8.count <= maxBytes { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
```

Create `mac/Sources/ClaudeBoardCore/ADPCMDecoder.swift` (same algorithm as `ios/Sources/Audio/ADPCMDecoder.swift`; the board's `adpcm_encode` is its inverse):

```swift
import Foundation

/// Decodes IMA ADPCM packets from the board: [seq u16][predictor i16][index u8][data, low nibble first],
/// 16 kHz mono. Every packet carries its own state, so a lost packet only needs matching silence.
public struct ADPCMDecoder: Sendable {
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
    /// Up to this many lost packets are replaced by silence (more: the gap is skipped)
    static let maxGapPackets = 10

    private var lastSeq: UInt16?

    public init() {}

    public mutating func decode(_ packet: Data) -> [Int16] {
        guard packet.count > 5 else { return [] }
        let bytes = [UInt8](packet)
        let seq = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var predictor = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
        var index = min(88, Int(bytes[4]))
        let samplesPerPacket = (bytes.count - 5) * 2

        var out: [Int16] = []
        if let lastSeq {
            let gap = Int(seq &- lastSeq) - 1
            if gap > 0 && gap <= Self.maxGapPackets {
                out.append(contentsOf: repeatElement(0, count: gap * samplesPerPacket))
            }
        }
        lastSeq = seq
        out.reserveCapacity(out.count + samplesPerPacket)
        for byte in bytes[5...] {
            for code in [Int(byte & 0x0f), Int(byte >> 4)] {
                let step = Self.stepTable[index]
                var delta = step >> 3
                if code & 4 != 0 { delta += step }
                if code & 2 != 0 { delta += step >> 1 }
                if code & 1 != 0 { delta += step >> 2 }
                predictor += (code & 8 != 0) ? -delta : delta
                predictor = min(32767, max(-32768, predictor))
                index = min(88, max(0, index + Self.indexTable[code]))
                out.append(Int16(predictor))
            }
        }
        return out
    }

    public mutating func reset() { lastSeq = nil }
}
```

- [ ] **Step 6: Run the tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings or errors; all tests pass (the previous 112 plus the 9 new ones).

- [ ] **Step 7: Commit**

```bash
git add mac/Sources/ClaudeBoardCore mac/Sources/claude-board/main.swift mac/Tests/ClaudeBoardCoreTests/VoiceProtocolTests.swift
git commit -F - <<'EOF'
mac: voice wire format (kind 8, voice inputs, session voice flag), typed-text rules, ADPCM decoder

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 2: Mac — tmux pane targets: hook ancestry, verification and typing

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/TmuxTyper.swift`
- Modify: `mac/Sources/ClaudeBoardCore/HookEnvelope.swift` (whole file), `mac/Sources/ClaudeBoardCore/HookEvent.swift` (ancestors), `mac/Sources/ClaudeBoardCore/Sessions.swift` (`VoiceTarget`), `mac/Sources/ClaudeBoardCore/SessionTracker.swift` (pane target, voice flag, `voiceTarget`), `mac/Sources/ClaudeBoardCore/SessionHub.swift` (`voiceTarget`), `mac/Sources/claude-board-hook/main.swift` (whole file)
- Test: `mac/Tests/ClaudeBoardCoreTests/TmuxTyperTests.swift` (new), `mac/Tests/ClaudeBoardCoreTests/HookEnvelopeTests.swift`, `mac/Tests/ClaudeBoardCoreTests/SocketProtocolTests.swift:55` (SIGPIPE fix), `mac/Tests/ClaudeBoardCoreTests/SessionTrackerTests.swift`

**Interfaces:**
- Consumes: `HookEvent.tmuxPane` / `tmuxSocket` (raw `$TMUX`), `SessionRow.voice` (Task 1).
- Produces (used by Tasks 4–6):
  - `public struct PaneTarget: Equatable, Sendable { public let pane: String; public let socket: String; public let ancestors: [Int32] }` (`public init(pane:socket:ancestors:)`)
  - `public enum TypeResult: Equatable, Sendable { case typed; case failed(String) }`
  - `public protocol PaneTyping: Sendable { func verify(_ target: PaneTarget) async -> String?; func type(_ text: String, into target: PaneTarget) async -> TypeResult }`
  - `public struct TmuxTyper: PaneTyping` with `public typealias Runner = @Sendable ([String]) async -> (status: Int32, output: String)`, `public init(run: Runner?, parentOf: @escaping @Sendable (Int32) -> Int32?, socketIsUsers: @escaping @Sendable (String) -> Bool, enterDelay: Duration = .milliseconds(200))`, `public static func system() -> TmuxTyper`, `public static let candidates: [String]`, `public static func processRunner(tmux: String) -> Runner`, `public static func socketIsUsers(_ path: String) -> Bool`, `static func literalArgument(_ text: String) -> String`, `public static let mark = "@claude_board"`
  - `public enum TmuxSocket { public static func path(fromTMUX value: String) -> String? }`
  - `public enum PaneCheck { public static func belongs(panePid: Int32, ancestors: [Int32], parentOf: (Int32) -> Int32?) -> Bool }`
  - `public enum ProcessTree { public static func parent(of pid: Int32) -> Int32?; public static func chain(from pid: Int32, max: Int = 8, parentOf: (Int32) -> Int32? = ProcessTree.parent(of:)) -> [Int32] }`
  - `HookEnvelope.augment(_ event: Data, environment: [String: String], ancestors: [Int32] = []) -> Data` (adds `claude_board_pids` only with a pane), `HookEvent.hookAncestors: [Int32]`
  - `public struct VoiceTarget: Equatable, Sendable { public let sessionId: String; public let project: String; public let state: SessionState; public let pane: PaneTarget? }` (`public init(sessionId:project:state:pane:)`)
  - `SessionTracker.voiceTarget(handle: UInt32) -> VoiceTarget?`, `SessionHub.voiceTarget(handle: UInt32) -> VoiceTarget?`; rows carry `voice` = the session has a `PaneTarget`

Why the ancestor chain: `$TMUX_PANE` alone does not prove the pane still runs this session (Claude may have exited, leaving a shell; pane ids are reused only after a server restart but the program inside changes). The hook records its parent process and that process's parents; the pane's root process (`pane_pid`) must appear in that chain, and if it is not the hook's direct parent, the chain member just below it (Claude Code, or `cb` exec'd into it) must still be its child.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/TmuxTyperTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

/// Records tmux invocations; answers display-message with `info`.
final class FakeTmux: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var info: String
    var infoStatus: Int32 = 0
    var sendStatus: [Int32] = []          // per send-keys call, default 0

    init(info: String) { self.info = info }

    var calls: [[String]] { lock.withLock { _calls } }
    var sendCalls: [[String]] { calls.filter { $0.contains("send-keys") } }

    var runner: TmuxTyper.Runner {
        { args in
            self.lock.withLock {
                self._calls.append(args)
                if args.contains("display-message") { return (self.infoStatus, self.info) }
                return (self.sendStatus.isEmpty ? 0 : self.sendStatus.removeFirst(), "")
            }
        }
    }
}

/// Hook parent 500 (Claude Code) whose parent is the pane process 400 (zsh), then the tmux server 300.
private let target = PaneTarget(pane: "%3", socket: "/tmp/s", ancestors: [500, 400, 300])
private let liveParents: @Sendable (Int32) -> Int32? = { [500: 400, 400: 300, 300: 1][$0] }

private func typer(_ fake: FakeTmux, parentOf: @escaping @Sendable (Int32) -> Int32? = liveParents,
                   socketIsUsers: Bool = true) -> TmuxTyper {
    TmuxTyper(run: fake.runner, parentOf: parentOf, socketIsUsers: { _ in socketIsUsers }, enterDelay: .zero)
}

private let goodInfo = "%3\t400\t0\t0\t1\n"

@Test func verifiedPaneGetsTheTextThenOneEnter() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).type("chạy các bài kiểm tra", into: target) == .typed)
    #expect(fake.calls.first == ["-S", "/tmp/s", "display-message", "-p", "-t", "%3",
                                 "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_in_mode}\t#{@claude_board}"])
    #expect(fake.sendCalls == [["-S", "/tmp/s", "send-keys", "-t", "%3", "-l", "--", "chạy các bài kiểm tra"],
                               ["-S", "/tmp/s", "send-keys", "-t", "%3", "Enter"]])
}

@Test func unmarkedPaneIsRefused() async {
    let fake = FakeTmux(info: "%3\t400\t0\t0\t\n")
    #expect(await typer(fake).type("x", into: target) == .failed("Open with cb for voice"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func paneOfAnotherProcessIsRefused() async {
    let fake = FakeTmux(info: "%3\t999\t0\t0\t1\n")
    #expect(await typer(fake).type("x", into: target) == .failed("The pane runs another program now — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func shellLeftInThePaneIsRefused() async {
    // Claude Code (500) exited: the pane process 400 is still there, but nothing below it is this session
    let fake = FakeTmux(info: goodInfo)
    let gone: @Sendable (Int32) -> Int32? = { [400: 300, 300: 1][$0] }
    #expect(await typer(fake, parentOf: gone).type("x", into: target) == .failed("The pane runs another program now — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func copyModeIsRefused() async {
    let fake = FakeTmux(info: "%3\t400\t0\t1\t1\n")
    #expect(await typer(fake).type("x", into: target) == .failed("The terminal is in copy mode — nothing sent"))
    #expect(fake.sendCalls.isEmpty)
}

@Test func deadOrMissingPaneIsRefused() async {
    let dead = FakeTmux(info: "%3\t400\t1\t0\t1\n")
    #expect(await typer(dead).type("x", into: target) == .failed("The tmux pane has exited — nothing sent"))
    let missing = FakeTmux(info: "")
    missing.infoStatus = 1
    #expect(await typer(missing).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    let other = FakeTmux(info: "%7\t400\t0\t0\t1\n")             // tmux resolved the target to another pane
    #expect(await typer(other).type("x", into: target) == .failed("The tmux pane is gone — nothing sent"))
    #expect(dead.sendCalls.isEmpty && missing.sendCalls.isEmpty && other.sendCalls.isEmpty)
}

@Test func foreignSocketIsRefused() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake, socketIsUsers: false).type("x", into: target) == .failed("tmux server not found — nothing sent"))
    #expect(fake.calls.isEmpty)
}

@Test func noTmuxOrNoTextIsRefused() async {
    let none = TmuxTyper(run: nil, parentOf: liveParents, socketIsUsers: { _ in true })
    #expect(await none.type("x", into: target) == .failed("tmux not found on the Mac — nothing sent"))
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).type("", into: target) == .failed("Nothing to send"))
    #expect(fake.calls.isEmpty)
}

@Test func failedTypingOrEnterIsReported() async {
    let fake = FakeTmux(info: goodInfo)
    fake.sendStatus = [1]
    #expect(await typer(fake).type("x", into: target) == .failed("tmux could not type — nothing sent"))
    #expect(fake.sendCalls.count == 1)                            // no Enter after a failed send
    let late = FakeTmux(info: goodInfo)
    late.sendStatus = [0, 1]
    #expect(await typer(late).type("x", into: target) == .failed("Typed, but Enter failed — press Enter in the terminal"))
}

@Test func verifyAloneTypesNothing() async {
    let fake = FakeTmux(info: goodInfo)
    #expect(await typer(fake).verify(target) == nil)
    #expect(fake.sendCalls.isEmpty)
}

@Test func trailingSemicolonIsEscaped() {
    // tmux strips a trailing ";" from an argument (command separator) and turns a trailing "\;" into ";"
    #expect(TmuxTyper.literalArgument("ok;") == "ok\\;")
    #expect(TmuxTyper.literalArgument("a\\;") == "a\\\\;")
    #expect(TmuxTyper.literalArgument("a;b") == "a;b")
    #expect(TmuxTyper.literalArgument("plain") == "plain")
}

@Test func paneCheckFollowsTheChain() {
    let parents: (Int32) -> Int32? = { [500: 400, 400: 300][$0] }
    #expect(PaneCheck.belongs(panePid: 500, ancestors: [500, 400], parentOf: parents))   // hook's direct parent
    #expect(PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: { _ in nil }))  // 500 is gone
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [500, 400], parentOf: { _ in 77 }))   // 500 re-parented
    #expect(!PaneCheck.belongs(panePid: 123, ancestors: [500, 400], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 1, ancestors: [1], parentOf: parents))
    #expect(!PaneCheck.belongs(panePid: 400, ancestors: [], parentOf: parents))
}

@Test func socketPathComesFromTheTMUXVariable() {
    #expect(TmuxSocket.path(fromTMUX: "/private/tmp/tmux-501/default,93688,0") == "/private/tmp/tmux-501/default")
    #expect(TmuxSocket.path(fromTMUX: "/tmp/s") == "/tmp/s")
    #expect(TmuxSocket.path(fromTMUX: "") == nil)
    #expect(TmuxSocket.path(fromTMUX: "relative,1,0") == nil)
}

@Test func processTreeSeesThisProcess() {
    #expect(ProcessTree.parent(of: getpid()) == getppid())
    #expect(ProcessTree.parent(of: 0) == nil)
    let chain = ProcessTree.chain(from: getpid())
    #expect(chain.first == getpid() && chain.count >= 2 && !chain.contains(1) && chain.count <= 8)
    #expect(ProcessTree.chain(from: 10, parentOf: { $0 - 1 }) == [10, 9, 8, 7, 6, 5, 4, 3])   // capped at 8
}

private let tmuxPath = TmuxTyper.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

@Test(.enabled(if: tmuxPath != nil, "tmux is not installed"))
func realTmuxTypesOnlyIntoAMarkedPane() async throws {
    let run = TmuxTyper.processRunner(tmux: try #require(tmuxPath))
    let sock = "/tmp/cbt-\(UInt32.random(in: 1...UInt32.max))"
    let (status, out) = await run(["-S", sock, "new-session", "-d", "-x", "160", "-y", "20",
                                   "-P", "-F", "#{pane_id} #{pane_pid}", "cat"])
    #expect(status == 0)
    let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    let pane = String(parts[0])
    let pid = try #require(Int32(parts[1]))
    let typer = TmuxTyper(run: run, parentOf: { ProcessTree.parent(of: $0) },
                          socketIsUsers: { TmuxTyper.socketIsUsers($0) }, enterDelay: .milliseconds(100))
    let paneTarget = PaneTarget(pane: pane, socket: sock, ancestors: [pid])
    #expect(await typer.type("hello", into: paneTarget) == .failed("Open with cb for voice"))
    _ = await run(["-S", sock, "set-option", "-p", "-t", pane, TmuxTyper.mark, "1"])
    let text = "-x {a} xin chào; ok \\;"                       // leading "-", braces, ";" inside, "\;" at the end
    #expect(await typer.type(text, into: paneTarget) == .typed)
    try await Task.sleep(for: .milliseconds(400))
    let (_, screen) = await run(["-S", sock, "capture-pane", "-p", "-t", pane])
    // The tty echoes the typed line, then cat prints it once Enter arrives: exactly two copies, one Enter
    #expect(screen.components(separatedBy: "\n").filter { $0 == text }.count == 2, "\(screen)")
    _ = await run(["-S", sock, "kill-server"])
}
```

The real-tmux test keeps the test process alive past 0.5 s, long enough for the fake daemons in `SocketProtocolTests.swift` to write to a socket the hook side already closed: that raises SIGPIPE and kills the whole test run ("exited with unexpected signal code 13"). In `mac/Tests/ClaudeBoardCoreTests/SocketProtocolTests.swift`, replace

```swift
func send(_ fd: Int32, _ s: String) { _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
```

with

```swift
/// Fake daemons keep writing after the hook side gave up: EPIPE, never a SIGPIPE that kills the test process
func send(_ fd: Int32, _ s: String) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
```

Append to `mac/Tests/ClaudeBoardCoreTests/HookEnvelopeTests.swift`:

```swift
@Test func envelopeAddsTheAncestorChainOnlyWithAPane() throws {
    let raw = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/p"}"#.utf8)
    let out = HookEnvelope.augment(raw, environment: ["TMUX_PANE": "%3", "TMUX": "/tmp/t,1,0"], ancestors: [700, 600])
    #expect(try HookEvent.parse(out).hookAncestors == [700, 600])
    let bare = HookEnvelope.augment(raw, environment: [:], ancestors: [700])
    #expect(object(bare)["claude_board_pids"] == nil)
    #expect(try HookEvent.parse(bare).hookAncestors == [])
}
```

Append to `mac/Tests/ClaudeBoardCoreTests/SessionTrackerTests.swift`:

```swift
private let paneExtra = #","claude_board_tmux_pane":"%4","claude_board_tmux":"/private/tmp/tmux-501/default,93688,0","claude_board_pids":[700,600]"#

@Test func voiceTargetNeedsPaneSocketAndAncestry() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit", extra: paneExtra), now: 1)
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta", extra: #","claude_board_tmux_pane":"%5""#), now: 2)
    let rows = t.rows()
    let alpha = rows.first { $0.project == "alpha" }!
    let beta = rows.first { $0.project == "beta" }!
    #expect(alpha.voice && !beta.voice)
    #expect(t.voiceTarget(handle: alpha.handle) == VoiceTarget(
        sessionId: "s1", project: "alpha", state: .working,
        pane: PaneTarget(pane: "%4", socket: "/private/tmp/tmux-501/default", ancestors: [700, 600])))
    #expect(t.voiceTarget(handle: beta.handle)?.pane == nil)
    #expect(t.voiceTarget(handle: 999) == nil)
    t.record(hookEvent("Stop"), now: 3)                        // an event without tmux keeps the target
    #expect(t.voiceTarget(handle: alpha.handle)?.pane?.pane == "%4")
    #expect(t.voiceTarget(handle: alpha.handle)?.state == .idle)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter "TmuxTyperTests|HookEnvelopeTests|SessionTrackerTests" 2>&1 | tail -20`
Expected: build errors (`cannot find 'PaneTarget' in scope`, `extra argument 'ancestors' in call`, …).

- [ ] **Step 3: Pane targets, verification and typing**

Create `mac/Sources/ClaudeBoardCore/TmuxTyper.swift`:

```swift
import Foundation

/// The tmux pane a session runs in, as its hooks reported it.
public struct PaneTarget: Equatable, Sendable {
    /// "%3" ($TMUX_PANE)
    public let pane: String
    /// tmux server socket ($TMUX up to its first comma)
    public let socket: String
    /// The hook's parent process and that process's parents, nearest first (HookEnvelope)
    public let ancestors: [Int32]

    public init(pane: String, socket: String, ancestors: [Int32]) {
        self.pane = pane
        self.socket = socket
        self.ancestors = ancestors
    }
}

public enum TypeResult: Equatable, Sendable {
    case typed
    /// Nothing was typed (except the documented Enter failure); the text is shown on the board
    case failed(String)
}

public protocol PaneTyping: Sendable {
    /// nil when `target` is a cb pane that still runs this session; else why not (shown on the board)
    func verify(_ target: PaneTarget) async -> String?
    /// Verifies again, then types `text` literally and presses Enter once
    func type(_ text: String, into target: PaneTarget) async -> TypeResult
}

public enum TmuxSocket {
    /// "$TMUX" is "<socket path>,<server pid>,<session index>"
    public static func path(fromTMUX value: String) -> String? {
        guard let first = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first,
              first.hasPrefix("/") else { return nil }
        return String(first)
    }
}

public enum PaneCheck {
    /// The pane's root process is in the session's recorded chain, and the chain member just below it (if any)
    /// is still its child: Claude Code (or cb exec'd into it) is still running in that pane.
    public static func belongs(panePid: Int32, ancestors: [Int32], parentOf: (Int32) -> Int32?) -> Bool {
        guard panePid > 1, let k = ancestors.firstIndex(of: panePid) else { return false }
        return k == 0 || parentOf(ancestors[k - 1]) == panePid
    }
}

public enum ProcessTree {
    /// Parent pid of a live process, nil when it does not exist
    public static func parent(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// pid, its parent, its grandparent… (at most `max`, stopping before launchd)
    public static func chain(from pid: Int32, max: Int = 8,
                             parentOf: (Int32) -> Int32? = ProcessTree.parent(of:)) -> [Int32] {
        var out: [Int32] = []
        var p = pid
        while p > 1 && out.count < max {
            out.append(p)
            guard let next = parentOf(p) else { break }
            p = next
        }
        return out
    }
}

/// Types voice text into a verified cb pane with `send-keys -l`, then one Enter.
public struct TmuxTyper: PaneTyping {
    public typealias Runner = @Sendable (_ arguments: [String]) async -> (status: Int32, output: String)

    /// Pane option set by mac/cb
    public static let mark = "@claude_board"
    public static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let infoFormat = "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_in_mode}\t#{\(mark)}"

    private let run: Runner?
    private let parentOf: @Sendable (Int32) -> Int32?
    private let socketIsUsers: @Sendable (String) -> Bool
    private let enterDelay: Duration

    public init(run: Runner?, parentOf: @escaping @Sendable (Int32) -> Int32?,
                socketIsUsers: @escaping @Sendable (String) -> Bool, enterDelay: Duration = .milliseconds(200)) {
        self.run = run
        self.parentOf = parentOf
        self.socketIsUsers = socketIsUsers
        self.enterDelay = enterDelay
    }

    /// The real tmux (Homebrew or system), the real process table and socket ownership check
    public static func system() -> TmuxTyper {
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return TmuxTyper(run: path.map { processRunner(tmux: $0) }, parentOf: { ProcessTree.parent(of: $0) },
                         socketIsUsers: { socketIsUsers($0) })
    }

    public func verify(_ t: PaneTarget) async -> String? {
        guard let run else { return "tmux not found on the Mac — nothing sent" }
        guard socketIsUsers(t.socket) else { return "tmux server not found — nothing sent" }
        let (status, out) = await run(["-S", t.socket, "display-message", "-p", "-t", t.pane, Self.infoFormat])
        let f = out.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard status == 0, f.count == 5, f[0] == t.pane, let panePid = Int32(f[1]) else {
            return "The tmux pane is gone — nothing sent"
        }
        guard f[2] == "0" else { return "The tmux pane has exited — nothing sent" }
        guard f[4] == "1" else { return "Open with cb for voice" }
        guard PaneCheck.belongs(panePid: panePid, ancestors: t.ancestors, parentOf: parentOf) else {
            return "The pane runs another program now — nothing sent"
        }
        guard f[3] == "0" else { return "The terminal is in copy mode — nothing sent" }
        return nil
    }

    public func type(_ text: String, into t: PaneTarget) async -> TypeResult {
        guard !text.isEmpty else { return .failed("Nothing to send") }
        if let problem = await verify(t) { return .failed(problem) }
        guard let run else { return .failed("tmux not found on the Mac — nothing sent") }
        let (typed, _) = await run(["-S", t.socket, "send-keys", "-t", t.pane, "-l", "--", Self.literalArgument(text)])
        guard typed == 0 else { return .failed("tmux could not type — nothing sent") }
        // Let Claude Code take the text as typing, not as part of a paste that would swallow the Enter
        try? await Task.sleep(for: enterDelay)
        let (entered, _) = await run(["-S", t.socket, "send-keys", "-t", t.pane, "Enter"])
        return entered == 0 ? .typed : .failed("Typed, but Enter failed — press Enter in the terminal")
    }

    /// tmux treats an argument ending in ";" as a command separator (and "\;" as a literal ";"): end such text
    /// with "\;" so the pane receives exactly `text`.
    static func literalArgument(_ text: String) -> String {
        text.hasSuffix(";") ? String(text.dropLast()) + "\\;" : text
    }

    /// Runs tmux without a shell (arguments are never interpreted); gives up after 5 s
    public static func processRunner(tmux: String) -> Runner {
        { args in
            await withCheckedContinuation { (c: CheckedContinuation<(status: Int32, output: String), Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tmux)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { proc in
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    c.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
                do {
                    try p.run()
                } catch {
                    c.resume(returning: (-1, ""))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            }
        }
    }

    /// A Unix socket owned by this user (never type into another user's tmux server)
    public static func socketIsUsers(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
    }
}
```

- [ ] **Step 4: Hook ancestry, session targets**

Replace the whole of `mac/Sources/ClaudeBoardCore/HookEnvelope.swift` with:

```swift
import Foundation

/// Hook side: the hook process inherits Claude Code's environment, so it can tell the daemon which tmux pane
/// the session runs in, and its own process ancestry so the daemon can later check that the pane still runs this
/// session (voice typing). Keys are prefixed so they never clash with Claude's.
public enum HookEnvelope {
    public static func augment(_ event: Data, environment: [String: String], ancestors: [Int32] = []) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any] else { return event }
        if let pane = environment["TMUX_PANE"], !pane.isEmpty {
            obj["claude_board_tmux_pane"] = pane
            if !ancestors.isEmpty { obj["claude_board_pids"] = ancestors.map { Int($0) } }
        }
        if let tmux = environment["TMUX"], !tmux.isEmpty { obj["claude_board_tmux"] = tmux }
        // Compact JSON has no raw newlines: the daemon reads exactly one line
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? event
    }
}
```

In `mac/Sources/ClaudeBoardCore/HookEvent.swift`: add after `public var tmuxSocket: String? = nil`:

```swift
    /// The hook's parent process and its parents, nearest first (only sent with a tmux pane)
    public var hookAncestors: [Int32] = []
```

add `let claude_board_pids: [Int32]?` to `Raw` after `let claude_board_tmux: String?`, and in `parse` replace `tmuxPane: r.claude_board_tmux_pane, tmuxSocket: r.claude_board_tmux)` with `tmuxPane: r.claude_board_tmux_pane, tmuxSocket: r.claude_board_tmux, hookAncestors: r.claude_board_pids ?? [])`.

Replace the whole of `mac/Sources/claude-board-hook/main.swift` with:

```swift
// Claude Code hook: forwards the event (plus $TMUX_PANE / $TMUX and, inside tmux, its process ancestry) to the
// claude-board daemon. PermissionRequest: prints the board's decision, or nothing (Claude shows its normal prompt).
import ClaudeBoardCore
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? HookEvent.parse(input) else { exit(0) }

let environment = ProcessInfo.processInfo.environment
let ancestors = (environment["TMUX_PANE"] ?? "").isEmpty ? [] : ProcessTree.chain(from: getppid())
let line = HookEnvelope.augment(input, environment: environment, ancestors: ancestors)
let isPermission = event.name == "PermissionRequest"
let reply = bridgeRoundTrip(event: line, waitForReply: isPermission, timeout: 92)

if isPermission, let out = HookOutput.output(for: reply) {
    print(out)
}
exit(0)
```

In `mac/Sources/ClaudeBoardCore/Sessions.swift`, append:

```swift
/// What a voice command needs to know about a session (VoiceHub)
public struct VoiceTarget: Equatable, Sendable {
    public let sessionId: String
    public let project: String
    public let state: SessionState
    /// nil: the session never reported a tmux pane with its socket and ancestry ("Open with cb for voice")
    public let pane: PaneTarget?

    public init(sessionId: String, project: String, state: SessionState, pane: PaneTarget?) {
        self.sessionId = sessionId
        self.project = project
        self.state = state
        self.pane = pane
    }
}
```

In `mac/Sources/ClaudeBoardCore/SessionTracker.swift`:

In `struct Session`, add after `var unseen: Bool`:

```swift
        /// Raw $TMUX and the hook's ancestry, from the last event that carried a pane
        var tmuxEnv: String? = nil
        var ancestors: [Int32] = []

        var paneTarget: PaneTarget? {
            guard let pane = tmuxPane, let env = tmuxEnv, let socket = TmuxSocket.path(fromTMUX: env),
                  !ancestors.isEmpty else { return nil }
            return PaneTarget(pane: pane, socket: socket, ancestors: ancestors)
        }
```

In `record(_:now:)`, replace `if let pane = e.tmuxPane, !pane.isEmpty { s.tmuxPane = pane }` with:

```swift
        if let pane = e.tmuxPane, !pane.isEmpty {
            s.tmuxPane = pane
            s.tmuxEnv = e.tmuxSocket
            s.ancestors = e.hookAncestors
        }
```

In `rows()`, replace `project: s.project, lastLine: s.lastLine)` with `project: s.project, lastLine: s.lastLine, voice: s.paneTarget != nil)`.

Add after `public func tmuxPane(sessionId:)`:

```swift
    public func voiceTarget(handle: UInt32) -> VoiceTarget? {
        guard let (id, s) = sessions.first(where: { $0.value.handle == handle }) else { return nil }
        return VoiceTarget(sessionId: id, project: s.project, state: s.state, pane: s.paneTarget)
    }
```

In `mac/Sources/ClaudeBoardCore/SessionHub.swift`, add after `public func tmuxPane(sessionId:)`:

```swift
    public func voiceTarget(handle: UInt32) -> VoiceTarget? { tracker.voiceTarget(handle: handle) }
```

- [ ] **Step 5: Run the tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings or errors; all tests pass, including `realTmuxTypesOnlyIntoAMarkedPane` (tmux is installed on this Mac; check it ran: `swift test --filter realTmux 2>&1 | grep -E "passed|skipped"` shows `passed`). If the real-tmux test fails on the braces or the trailing `\;`, fix `literalArgument` for what tmux actually does (keep the fake-runner expectations in step with it) — the pane must receive exactly `text`.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources mac/Tests
git commit -F - <<'EOF'
mac: tmux pane targets (hook ancestry, cb mark, copy mode) and literal typing with send-keys -l

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 3: Mac — Other answers and deny with reason in the request queue and the hook reply

**Files:**
- Modify: `mac/Sources/ClaudeBoardCore/RequestQueue.swift` (whole file), `mac/Sources/ClaudeBoardCore/AnswerMapping.swift` (`permissionReply`, `chosenLabels`, `boardAnswerText`, `questionReply`), `mac/Sources/ClaudeBoardCore/HookProcessor.swift:87-88`
- Test: `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift`, `mac/Tests/ClaudeBoardCoreTests/AnswerMappingTests.swift`, `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`

**Interfaces:**
- Consumes: `BoardInput` (Task 1; masks may carry bit 7), `HookSchema.questionAnswers` (`.updatedInputJoined`, verified in Phase 2), `HookSchema.denyMessageKey` (`message`).
- Produces (used by Task 4):
  - `BoardResponse.answers([UInt8], others: [Int: String] = [:])` (question index → spoken Other text, only for masks with bit 7), `BoardResponse.denyWithReason(String)`
  - `RequestShape.otherBit: UInt8 = 0x80`, `RequestShape.accept(_ input: BoardInput, others: Set<Int> = []) -> BoardResponse?`
  - `RequestQueue.shownShape(id: UInt32) -> RequestShape?` (the shape of the request on the board, if `id` is it)
  - `RequestQueue.setOther(id: UInt32, question: Int, text: String) -> Bool` (only for the shown question request, question in range, text non-empty; a later call replaces the text)
  - `RequestQueue.denyWithReason(id: UInt32, message: String, notice: BoardMessage? = nil) -> Bool` (only for the shown permission request; `notice` is queued right after the decision, before the next request is shown)
  - `AnswerMapping.denyReasonText(_ spoken: String) -> String` = `"The user denied this on the board and said: <spoken>"`
  - `AnswerMapping.chosenLabels(_:_:others:)`, `boardAnswerText(_:questions:others:)`, `questionReply(_:others:questions:toolInput:style:)` (`others` defaults to `[:]`)

An Other answer is a free-text answer: with the verified `updatedInputJoined` style Claude receives `answers[question] = "<spoken text>"` (single-select) or `"<label>, <label>, <spoken text>"` (multi-select, Other last), exactly as if typed into Claude Code's own "Other" field.

- [ ] **Step 1: Write the failing tests**

Append to `mac/Tests/ClaudeBoardCoreTests/RequestQueueTests.swift`:

```swift
@Test func otherAnswerNeedsTheSpokenText() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.questionIds()[0]
    await q.handle(.answers(id: id, masks: [0x80, 0b001]))          // Other on page 1, but nothing spoken yet
    #expect(await q.shownShape(id: id) != nil)                     // still waiting
    #expect(await q.setOther(id: id, question: 0, text: "Tím"))
    #expect(await q.setOther(id: id, question: 0, text: "Tím than"))   // Say again replaces it
    await q.handle(.answers(id: id, masks: [0x80, 0b101]))
    #expect(await r == .answers([0x80, 0b101], others: [0: "Tím than"]))
}

@Test func otherTextIsOnlySentForTicked() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let r = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(50))
    let id = await sent.questionIds()[0]
    #expect(await q.setOther(id: id, question: 1, text: "Durian"))
    await q.handle(.answers(id: id, masks: [0b10, 0b001]))          // spoken, then not ticked: not part of the answer
    #expect(await r == .answers([0b10, 0b001]))
}

@Test func otherCombinesOnlyOnMultiSelect() {
    let shape = RequestShape.question(options: [2, 3], multi: [false, true])
    #expect(shape.accept(.answers(id: 1, masks: [0x81, 0b1]), others: [0]) == nil)       // single: one choice only
    #expect(shape.accept(.answers(id: 1, masks: [0b1, 0x81]), others: [1]) == .answers([0b1, 0x81]))
    #expect(shape.accept(.answers(id: 1, masks: [0b1, 0x80]), others: []) == nil)        // no text for page 2
}

@Test func setOtherOnlyForTheShownQuestion() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let p = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let r = askQuestions(q)                                    // queued behind the permission
    try? await Task.sleep(for: .milliseconds(30))
    let permission = await sent.permissionIds()[0]
    #expect(await !q.setOther(id: permission, question: 0, text: "x"))   // not a question
    #expect(await !q.setOther(id: permission &+ 1, question: 0, text: "x"))   // not shown (queued or unknown)
    await q.handle(.choice(id: permission, .deny))
    try? await Task.sleep(for: .milliseconds(30))
    let question = await sent.questionIds()[0]
    #expect(await !q.setOther(id: question, question: 2, text: "x"))     // only 2 questions
    #expect(await !q.setOther(id: question, question: 0, text: ""))      // nothing spoken
    #expect(await q.setOther(id: question, question: 1, text: "Durian"))
    await q.handle(.answers(id: question, masks: [0b1, 0x80]))
    #expect(await p == .deny)
    #expect(await r == .answers([0b1, 0x80], others: [1: "Durian"]))
}

@Test func denyWithReasonOnlyForTheShownPermission() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(project: "p", tool: "Bash", summary: "one")
    try? await Task.sleep(for: .milliseconds(30))
    async let b = askQuestions(q)
    try? await Task.sleep(for: .milliseconds(30))
    let first = await sent.permissionIds()[0]
    #expect(await !q.denyWithReason(id: first &+ 999, message: "no"))
    #expect(await !q.denyWithReason(id: first, message: ""))
    let notice = BoardMessage.voice(id: 9, .done("Denied with your reason"))
    #expect(await q.denyWithReason(id: first, message: "dùng pnpm thay vì npm", notice: notice))
    #expect(await a == .denyWithReason("dùng pnpm thay vì npm"))
    try? await Task.sleep(for: .milliseconds(30))
    let question = await sent.questionIds()[0]
    #expect(await !q.denyWithReason(id: question, message: "no"))        // a question is not denied this way
    // The notice reaches the board before the next request, and no cancel is sent for an answered request
    let order = await sent.messages
    let noticeAt = order.firstIndex(of: notice)
    let nextAt = order.firstIndex { if case .question = $0 { true } else { false } }
    #expect(noticeAt != nil && nextAt != nil && noticeAt! < nextAt!)
    #expect(!order.contains(.cancel(id: first)))
    await q.handle(.answers(id: question, masks: [0b1, 0b1]))
    _ = await b
}

@Test func shownShapeIsOnlyTheHead() async {
    let sent = Sent()
    let q = RequestQueue(send: { await sent.add($0) })
    async let a = q.ask(shape: .permission(alwaysOffered: true)) { id in
        [.permission(id: id, project: "p", tool: "Bash", summary: "x", alwaysRule: "Bash(x)")]
    }
    try? await Task.sleep(for: .milliseconds(30))
    let id = await sent.permissionIds()[0]
    #expect(await q.shownShape(id: id) == .permission(alwaysOffered: true))
    #expect(await q.shownShape(id: id &+ 1) == nil)
    await q.handle(.choice(id: id, .allow))
    #expect(await a == .allow)
    #expect(await q.shownShape(id: id) == nil)
}
```

Append to `mac/Tests/ClaudeBoardCoreTests/AnswerMappingTests.swift`:

```swift
@Test func otherTextBecomesTheAnswer() throws {
    let input: [String: JSONValue] = ["questions": .array([])]
    let r = AnswerMapping.questionReply([0x80, 0x80 | 0b001], others: [0: "Tím than", 1: "Sầu riêng"], questions: qs,
                                        toolInput: input, style: .updatedInputJoined)
    let answers = r.updatedInput?.object?["answers"]?.object
    #expect(r.decision == "allow")
    #expect(answers?[qs[0].question] == .string("Tím than"))
    #expect(answers?[qs[1].question] == .string("Apple, Sầu riêng"))
    #expect(AnswerMapping.chosenLabels([0x80, 0b1], qs, others: [:]) == [[], ["Apple"]])     // no text: nothing
    #expect(AnswerMapping.boardAnswerText([0x80, 0b1], questions: qs, others: [0: "Tím"])
            == "The user answered on the board: \(qs[0].question) → Tím; \(qs[1].question) → Apple")
}

@Test func denyWithReasonCarriesTheSpokenText() {
    let r = AnswerMapping.permissionReply(.denyWithReason("dùng pnpm"), suggestions: nil)
    #expect(r == BridgeReply(decision: "deny", message: "The user denied this on the board and said: dùng pnpm"))
    #expect(HookOutput.output(for: r)?.contains("\"message\":\"The user denied this on the board and said: dùng pnpm\"") == true)
}
```

(`qs` is the fixture at the top of that file: "Which color?" single-select Red/Green/Blue, "Which fruits?" multi-select Apple/Banana/Cherry.)

Append to `mac/Tests/ClaudeBoardCoreTests/HookProcessorTests.swift`:

```swift
@Test func denyWithReasonReachesTheHook() async {
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(permissionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let id = board.permissionIds[0]
    #expect(await p.requests.denyWithReason(id: id, message: "chạy pnpm test thay vì npm test"))
    await done.value
    #expect(conn.replies == [BridgeReply(decision: "deny",
                                         message: "The user denied this on the board and said: chạy pnpm test thay vì npm test")])
}

@Test func questionWithOtherRepliesWithTheSpokenText() async throws {
    if HookSchema.questionAnswers == .terminalOnly { return }
    let (p, board) = makeProcessor(ready: true)
    let conn = FakeConn()
    let done = Task { await p.process(questionLine, conn) }
    try? await Task.sleep(for: .milliseconds(50))
    let id = pages(board)[0].id
    #expect(await p.requests.setOther(id: id, question: 0, text: "Tím"))
    await p.requests.handle(.answers(id: id, masks: [0x80, 0b101]))
    await done.value
    let e = try HookEvent.parse(questionLine)
    let expected = AnswerMapping.questionReply([0x80, 0b101], others: [0: "Tím"],
                                               questions: try #require(AskQuestion.parse(e.toolInput)), toolInput: e.toolInput)
    #expect(conn.replies == [expected])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter "RequestQueueTests|AnswerMappingTests|HookProcessorTests" 2>&1 | tail -20`
Expected: build errors (`extra argument 'others' in call`, `value of type 'RequestQueue' has no member 'setOther'`, …).

- [ ] **Step 3: Request queue**

Replace the whole of `mac/Sources/ClaudeBoardCore/RequestQueue.swift` with:

```swift
import Foundation

/// What the board answered for the request it showed.
public enum BoardResponse: Equatable, Sendable {
    case allow, deny, alwaysAllow
    /// One bitmask per question: bit i = option i chosen, bit 7 = the spoken Other answer (its text in `others`)
    case answers([UInt8], others: [Int: String] = [:])
    /// Deny with the reason the user spoke on the board
    case denyWithReason(String)
}

/// The answers a request accepts.
public enum RequestShape: Equatable, Sendable {
    case permission(alwaysOffered: Bool)
    /// options[q] = option count of question q; multi[q] = several options may be chosen
    case question(options: [Int], multi: [Bool])

    /// Mask bit of a question's spoken Other answer
    public static let otherBit: UInt8 = 0x80

    /// The response a board input stands for, or nil when it does not fit this request. `others`: questions
    /// that have a spoken Other text (bit 7 is only valid for those).
    public func accept(_ input: BoardInput, others: Set<Int> = []) -> BoardResponse? {
        switch (self, input) {
        case (.permission(let always), .choice(_, let c)):
            switch c {
            case .allow: return .allow
            case .deny: return .deny
            case .alwaysAllow: return always ? .alwaysAllow : nil
            }
        case (.question(let options, let multi), .answers(_, let masks)):
            guard masks.count == options.count, multi.count == options.count else { return nil }
            for (i, m) in masks.enumerated() {
                guard (1...7).contains(options[i]) else { return nil }
                var valid = UInt8(truncatingIfNeeded: (1 << options[i]) - 1)
                if others.contains(i) { valid |= Self.otherBit }
                guard m != 0, m & ~valid == 0, multi[i] || m.nonzeroBitCount == 1 else { return nil }
            }
            return .answers(masks)
        default:
            return nil
        }
    }
}

public actor RequestQueue {
    private struct Pending {
        let id: UInt32
        let messages: [BoardMessage]
        let shape: RequestShape
        var continuation: CheckedContinuation<BoardResponse?, Never>?
        /// Spoken Other answers stored by the board's voice Send (question index → text)
        var others: [Int: String] = [:]
    }

    private let outbox: AsyncStream<BoardMessage>.Continuation   // single FIFO so board traffic never reorders
    private let timeout: Duration
    private var queue: [Pending] = []          // queue[0] is on the board
    private var nextId = UInt32.random(in: 1 ... 0x7fff_ffff)

    public init(send: @escaping @Sendable (BoardMessage) async -> Void, timeout: Duration = .seconds(90)) {
        let (stream, continuation) = AsyncStream<BoardMessage>.makeStream()
        self.outbox = continuation
        self.timeout = timeout
        Task {
            for await message in stream { await send(message) }
        }
    }

    deinit { outbox.finish() }

    /// Ids are never 0: the board uses 0 as "no pending request" and for its own events.
    private func allocateId() -> UInt32 {
        if nextId == 0 { nextId = 1 }
        let id = nextId
        nextId &+= 1
        return id
    }

    func seedNextId(_ value: UInt32) { nextId = value }

    /// Shows a request on the board (when it reaches the head of the queue) and waits for its answer.
    /// nil = timeout, cancellation (the hook went away) or the board disconnected: never a decision.
    public func ask(shape: RequestShape, messages build: @Sendable (UInt32) -> [BoardMessage]) async -> BoardResponse? {
        let id = allocateId()
        let messages = build(id)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.finish(id, with: nil, cancelOnBoard: true) }   // runs on the queue
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                queue.append(Pending(id: id, messages: messages, shape: shape, continuation: c))
                if queue.count == 1 { show(messages) }
            }
        } onCancel: {
            Task { await self.finish(id, with: nil, cancelOnBoard: true) }
        }
    }

    /// A permission request without "Always allow".
    public func ask(project: String, tool: String, summary: String) async -> BoardResponse? {
        await ask(shape: .permission(alwaysOffered: false)) { id in
            [.permission(id: id, project: project, tool: tool, summary: summary)]
        }
    }

    /// Only the request shown on the board can be answered, and only with an answer of its shape.
    public func handle(_ input: BoardInput) {
        let id: UInt32
        switch input {
        case .choice(let i, _), .answers(let i, _): id = i
        case .mode, .focus, .voiceStart, .voiceStop, .voiceCancel, .voiceSend: return
        }
        guard let head = queue.first, head.id == id,
              let response = head.shape.accept(input, others: Set(head.others.keys)) else { return }
        if case .answers(let masks, _) = response {
            let spoken = head.others.filter { q, _ in masks.indices.contains(q) && masks[q] & RequestShape.otherBit != 0 }
            finish(id, with: .answers(masks, others: spoken), cancelOnBoard: false)
        } else {
            finish(id, with: response, cancelOnBoard: false)
        }
    }

    /// The shape of the request on the board, if `id` is that request.
    public func shownShape(id: UInt32) -> RequestShape? {
        guard let head = queue.first, head.id == id else { return nil }
        return head.shape
    }

    /// Stores the spoken Other answer for question `question` of the question request on the board. It becomes
    /// part of the answer only if the board's answers tick it (bit 7). A later call replaces the text.
    public func setOther(id: UInt32, question: Int, text: String) -> Bool {
        guard !text.isEmpty, let head = queue.first, head.id == id,
              case .question(let options, _) = head.shape, options.indices.contains(question) else { return false }
        queue[0].others[question] = text
        return true
    }

    /// Denies the permission request on the board with the spoken reason. `notice` goes to the board right after
    /// the decision, before the next request is shown.
    public func denyWithReason(id: UInt32, message: String, notice: BoardMessage? = nil) -> Bool {
        guard !message.isEmpty, let head = queue.first, head.id == id, case .permission = head.shape else { return false }
        finish(id, with: .denyWithReason(message), cancelOnBoard: false, notice: notice)
        return true
    }

    /// Non-request traffic (session rows, voice transcripts): same FIFO, so it never overtakes a request or a cancel.
    public func post(_ message: BoardMessage) {
        outbox.yield(message)
    }

    public func boardDisconnected() {
        let all = queue
        queue.removeAll()
        for p in all { p.continuation?.resume(returning: nil) }
    }

    public func notifyFinished(project: String, line: String) async {
        outbox.yield(.finished(id: allocateId(), project: project, line: line))
    }

    private func show(_ messages: [BoardMessage]) {
        for m in messages { outbox.yield(m) }
    }

    private func finish(_ id: UInt32, with response: BoardResponse?, cancelOnBoard: Bool, notice: BoardMessage? = nil) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasShown = index == 0
        let p = queue.remove(at: index)
        p.continuation?.resume(returning: response)
        if let notice { outbox.yield(notice) }
        if wasShown {
            if cancelOnBoard { outbox.yield(.cancel(id: id)) }
            if let next = queue.first { show(next.messages) }
        }
    }
}
```

(The option-count guard moves from `1...8` to `1...7`: bit 7 is the Other answer now; `AskQuestion` allows at most 4 options anyway.)

- [ ] **Step 4: Answer mapping and the processor**

In `mac/Sources/ClaudeBoardCore/AnswerMapping.swift`:

In `permissionReply`, replace

```swift
        case .answers:
            return BridgeReply(decision: nil)
```

with

```swift
        case .denyWithReason(let spoken):
            return BridgeReply(decision: "deny", message: denyReasonText(spoken))
        case .answers:
            return BridgeReply(decision: nil)
```

Replace `chosenLabels`, `boardAnswerText` and the head of `questionReply` (down to the `switch style {` line) with:

```swift
    /// What Claude reads when the user denies with a spoken reason
    public static func denyReasonText(_ spoken: String) -> String {
        "The user denied this on the board and said: \(spoken)"
    }

    /// Labels chosen per question, in option order (labels from the original tool_input, never the cut ones),
    /// then the spoken Other text when bit 7 is set and a text exists.
    public static func chosenLabels(_ masks: [UInt8], _ questions: [AskQuestion], others: [Int: String] = [:]) -> [[String]] {
        zip(masks, questions).enumerated().map { i, pair in
            let (mask, q) = pair
            var labels = q.options.indices.filter { mask & (1 << $0) != 0 }.map { q.options[$0].label }
            if mask & RequestShape.otherBit != 0, let spoken = others[i] { labels.append(spoken) }
            return labels
        }
    }

    /// The spec's fallback text: "The user answered on the board: <question> → <choice>[; …]"
    public static func boardAnswerText(_ masks: [UInt8], questions: [AskQuestion], others: [Int: String] = [:]) -> String {
        let parts = zip(questions, chosenLabels(masks, questions, others: others)).map { q, labels in
            "\(q.question) → \(labels.joined(separator: ", "))"
        }
        return "The user answered on the board: " + parts.joined(separator: "; ")
    }

    public static func questionReply(_ masks: [UInt8], others: [Int: String] = [:], questions: [AskQuestion],
                                     toolInput: [String: JSONValue],
                                     style: QuestionAnswerStyle = HookSchema.questionAnswers) -> BridgeReply {
        switch style {
        case .denyWithReason:
            return BridgeReply(decision: "deny", message: boardAnswerText(masks, questions: questions, others: others))
        case .updatedInputJoined, .updatedInputArrays:
            var answers: [String: JSONValue] = [:]
            for (q, labels) in zip(questions, chosenLabels(masks, questions, others: others)) {
```

(the rest of `questionReply` — the `answers[q.question] = …` body, `updatedInput`, `.terminalOnly` — stays as it is).

In `mac/Sources/ClaudeBoardCore/HookProcessor.swift`, `askQuestion`, replace

```swift
        guard case .answers(let masks) = response else { return BridgeReply(decision: nil) }
        return AnswerMapping.questionReply(masks, questions: questions, toolInput: e.toolInput)
```

with

```swift
        guard case .answers(let masks, let others) = response else { return BridgeReply(decision: nil) }
        return AnswerMapping.questionReply(masks, others: others, questions: questions, toolInput: e.toolInput)
```

- [ ] **Step 5: Run the tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings or errors; all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/ClaudeBoardCore mac/Tests/ClaudeBoardCoreTests
git commit -F - <<'EOF'
mac: spoken Other answers (mask bit 7) and deny with a spoken reason, only for the request on the board

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 4: Mac — the voice hub (capture state machine, pure with injected engine and typer)

**Files:**
- Create: `mac/Sources/ClaudeBoardCore/VoiceHub.swift`
- Test: `mac/Tests/ClaudeBoardCoreTests/VoiceHubTests.swift`

**Interfaces:**
- Consumes: `BoardInput` voice cases, `VoiceUpdate`, `BoardMessage.voice`, `VoiceText.forTyping`, `ADPCMDecoder` (Task 1); `PaneTarget`, `PaneTyping`, `TypeResult`, `VoiceTarget` (Task 2); `RequestQueue.post`, `shownShape(id:)`, `setOther(id:question:text:)`, `denyWithReason(id:message:notice:)` (Task 3).
- Produces (used by Task 5):
  - `public enum VoiceConfig { public static let localeIdentifier = "vi_VN" }`
  - `public protocol VoiceEngine: Sendable { func prepare() async -> String?; func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream }`
  - `public protocol VoiceStream: AnyObject, Sendable { func feed(_ samples: [Int16]); func finish() async -> String; func cancel() async }`
  - `public actor VoiceHub` with `public init(engine: (any VoiceEngine)?, typer: any PaneTyping, requests: RequestQueue, target: @escaping @Sendable (UInt32) async -> VoiceTarget?, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }, maxCapture: Duration = .seconds(120), log: @escaping @Sendable (String) -> Void = { _ in })`, `public func input(_ input: BoardInput) async`, `public func audio(_ packet: Data)`, `public func boardDisconnected() async`, `public static let partialInterval: Double = 0.25`

Board-visible messages (exact strings, the board shows them as they are): start errors "Voice needs macOS 26 on the Mac", the engine's own `prepare()` reason, "Session not found", "This session has ended", "Open with cb for voice", the typer's `verify` reason, "The question is no longer on the board", "The request is no longer on the board", "Speech recognition did not start", "Timed out — say it again"; send results "Sent to <project>", "Added as your answer", "Denied with your reason"; send errors "Nothing to send", "Session not found — nothing sent", "Claude is waiting for an answer in the terminal — nothing sent", "This session has ended — nothing sent", "Open with cb for voice", the typer's `type` failure.

- [ ] **Step 1: Write the failing tests**

Create `mac/Tests/ClaudeBoardCoreTests/VoiceHubTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeBoardCore

final class FakeStream: VoiceStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _fed = 0
    private var _cancelled = false
    private let text: String
    private let finishDelay: Duration

    init(text: String, finishDelay: Duration) { self.text = text; self.finishDelay = finishDelay }

    func feed(_ samples: [Int16]) { lock.withLock { _fed += samples.count } }
    func finish() async -> String { try? await Task.sleep(for: finishDelay); return text }
    func cancel() async { lock.withLock { _cancelled = true } }
    var fed: Int { lock.withLock { _fed } }
    var cancelled: Bool { lock.withLock { _cancelled } }
}

final class FakeEngine: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [String]
    private var _streams: [FakeStream] = []
    private var onPartial: (@Sendable (String) -> Void)?
    var unavailable: String? { get { lock.withLock { _unavailable } } set { lock.withLock { _unavailable = newValue } } }
    private var _unavailable: String?
    let beginDelay: Duration
    let finishDelay: Duration

    init(finals: [String], beginDelay: Duration = .zero, finishDelay: Duration = .zero) {
        self.finals = finals
        self.beginDelay = beginDelay
        self.finishDelay = finishDelay
    }

    func prepare() async -> String? { unavailable }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        try? await Task.sleep(for: beginDelay)
        return lock.withLock {
            let s = FakeStream(text: finals.isEmpty ? "" : finals.removeFirst(), finishDelay: finishDelay)
            _streams.append(s)
            self.onPartial = onPartial
            return s
        }
    }

    var streams: [FakeStream] { lock.withLock { _streams } }
    func say(_ text: String) { lock.withLock { onPartial }?(text) }
}

final class FakeTyper: PaneTyping, @unchecked Sendable {
    private let lock = NSLock()
    private var _typed: [(String, PaneTarget)] = []
    var verifyResult: String?
    var typeResult: TypeResult = .typed

    func verify(_ target: PaneTarget) async -> String? { lock.withLock { verifyResult } }
    func type(_ text: String, into target: PaneTarget) async -> TypeResult {
        lock.withLock { _typed.append((text, target)); return typeResult }
    }
    var typed: [String] { lock.withLock { _typed.map(\.0) } }
    var panes: [PaneTarget] { lock.withLock { _typed.map(\.1) } }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double = 1_000
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
}

final class Targets: @unchecked Sendable {
    private let lock = NSLock()
    private var byHandle: [UInt32: VoiceTarget]
    init(_ byHandle: [UInt32: VoiceTarget]) { self.byHandle = byHandle }
    func get(_ h: UInt32) -> VoiceTarget? { lock.withLock { byHandle[h] } }
}

extension Sent {
    func updates(_ voice: UInt32) -> [VoiceUpdate] {
        messages.compactMap { if case .voice(let id, let u) = $0, id == voice { u } else { nil } }
    }
}

private let pane = PaneTarget(pane: "%3", socket: "/tmp/s", ancestors: [500, 400])
private func session(_ state: SessionState = .idle, pane p: PaneTarget? = pane) -> VoiceTarget {
    VoiceTarget(sessionId: "s1", project: "esp32", state: state, pane: p)
}

private func packet(_ seq: UInt8) -> Data { Data([seq, 0, 0, 0, 0, 0x07]) }   // 2 samples

private struct Rig {
    let hub: VoiceHub
    let sent: Sent
    let requests: RequestQueue
    let engine: FakeEngine?
    let typer: FakeTyper
    let clock: FakeClock
}

private func rig(engine: FakeEngine? = FakeEngine(finals: ["  chạy\ncác bài kiểm tra "]),
                 target: VoiceTarget? = session(), maxCapture: Duration = .seconds(120)) -> Rig {
    let sent = Sent()
    let requests = RequestQueue(send: { await sent.add($0) })
    let typer = FakeTyper()
    let clock = FakeClock()
    let targets = Targets(target.map { [7: $0] } ?? [:])
    let hub = VoiceHub(engine: engine, typer: typer, requests: requests, target: { targets.get($0) },
                       clock: { clock.now }, maxCapture: maxCapture)
    return Rig(hub: hub, sent: sent, requests: requests, engine: engine, typer: typer, clock: clock)
}

private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

@Test func commandIsTypedOnlyAfterSend() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.audio(packet(0))
    await r.hub.audio(packet(1))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.audio(packet(2))                                  // after stop: ignored
    await settle()
    #expect(await r.sent.updates(9) == [.final("chạy các bài kiểm tra")])
    #expect(r.engine!.streams[0].fed == 4)
    #expect(r.typer.typed.isEmpty)                                // nothing before an explicit Send
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(r.typer.typed == ["chạy các bài kiểm tra"] && r.typer.panes == [pane])
    #expect(await r.sent.updates(9).last == .done("Sent to esp32"))
    await r.hub.input(.voiceSend(voice: 9))                       // a second Send: the capture is over
    #expect(r.typer.typed.count == 1)
}

@Test func stopBeforeTheEngineIsReadyStillFinishes() async {
    let r = rig(engine: FakeEngine(finals: ["xin chào"], beginDelay: .milliseconds(100)))
    let starting = Task { await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7)) }
    try? await Task.sleep(for: .milliseconds(30))
    await r.hub.audio(packet(0))                                  // buffered until the engine is ready
    await r.hub.input(.voiceStop(voice: 9))
    await starting.value
    await settle()
    #expect(r.engine!.streams[0].fed == 2)
    #expect(await r.sent.updates(9) == [.final("xin chào")])
}

@Test func emptyTranscriptIsNeverTyped() async {
    let r = rig(engine: FakeEngine(finals: ["  ! /  "]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final(""), .error("Nothing to send")])
    #expect(r.typer.typed.isEmpty)
}

@Test func needsYouIsNeverTypedInto() async {
    let r = rig(target: session(.needsYou))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9).last == .error("Claude is waiting for an answer in the terminal — nothing sent"))
    #expect(r.typer.typed.isEmpty)
}

@Test func startErrorsComeBeforeAnyRecording() async {
    let noPane = rig(target: session(pane: nil))
    await noPane.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let ended = rig(target: session(.ended))
    await ended.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let unknown = rig(target: nil)
    await unknown.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let unverified = rig()
    unverified.typer.verifyResult = "The tmux pane is gone — nothing sent"
    await unverified.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await settle()
    #expect(await noPane.sent.updates(9) == [.error("Open with cb for voice")])
    #expect(await ended.sent.updates(9) == [.error("This session has ended")])
    #expect(await unknown.sent.updates(9) == [.error("Session not found")])
    #expect(await unverified.sent.updates(9) == [.error("The tmux pane is gone — nothing sent")])
    for r in [noPane, ended, unknown, unverified] { #expect(r.engine!.streams.isEmpty) }
}

@Test func typingFailureIsShown() async {
    let r = rig()
    r.typer.typeResult = .failed("The pane runs another program now — nothing sent")
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9).last == .error("The pane runs another program now — nothing sent"))
}

@Test func engineMissingOrUnavailable() async {
    let none = rig(engine: nil)
    await none.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let engine = FakeEngine(finals: ["a", "b"])
    engine.unavailable = "Allow Speech Recognition for claude-board in System Settings"
    let denied = rig(engine: engine)
    await denied.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    engine.unavailable = nil                                      // granted later: not cached as a failure
    await denied.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))
    await denied.hub.input(.voiceStop(voice: 10))
    await settle()
    #expect(await none.sent.updates(9) == [.error("Voice needs macOS 26 on the Mac")])
    #expect(await denied.sent.updates(9) == [.error("Allow Speech Recognition for claude-board in System Settings")])
    #expect(await denied.sent.updates(10) == [.final("a")])
}

@Test func staleVoiceIdsAreIgnored() async {
    let r = rig(engine: FakeEngine(finals: ["một", "hai"]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))   // Say again (replaces 9)
    await r.hub.input(.voiceSend(voice: 9))                                    // stale: ignored
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceCancel(voice: 9))
    #expect(r.typer.typed.isEmpty)
    await r.hub.input(.voiceStop(voice: 10))
    await r.hub.input(.voiceSend(voice: 10))
    await settle()
    #expect(r.typer.typed == ["hai"])
    #expect(await r.sent.updates(9) == [.final("một")])
}

@Test func aNewStartCancelsTheRunningCapture() async {
    let r = rig(engine: FakeEngine(finals: ["một", "hai"]))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceStart(voice: 10, purpose: .command, target: 7))
    #expect(r.engine!.streams[0].cancelled)
}

@Test func sendBeforeTheFinalIsIgnored() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.typer.typed.isEmpty)
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.typer.typed == ["chạy các bài kiểm tra"])
}

@Test func cancelWhileFinishingDropsTheText() async {
    let r = rig(engine: FakeEngine(finals: ["xin chào"], finishDelay: .milliseconds(150)))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    let stopping = Task { await r.hub.input(.voiceStop(voice: 9)) }
    try? await Task.sleep(for: .milliseconds(40))
    await r.hub.input(.voiceCancel(voice: 9))
    await stopping.value
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(r.engine!.streams[0].cancelled)
    #expect(await r.sent.updates(9).isEmpty)
    #expect(r.typer.typed.isEmpty)
}

@Test func disconnectDropsTheCapture() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    await r.hub.boardDisconnected()
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(r.engine!.streams[0].cancelled && r.typer.typed.isEmpty)
}

@Test func partialsAreThrottledAndStopAtStop() async {
    let r = rig()
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    r.engine!.say("chạy");             await settle()
    r.clock.advance(0.1)
    r.engine!.say("chạy các");         await settle()               // within 250 ms: dropped
    r.clock.advance(0.2)
    r.engine!.say("chạy các bài");     await settle()
    r.clock.advance(0.3)
    r.engine!.say("chạy các bài");     await settle()               // unchanged: dropped
    await r.hub.input(.voiceStop(voice: 9))
    r.clock.advance(0.3)
    r.engine!.say("chạy các bài kiểm"); await settle()              // after stop: dropped
    #expect(await r.sent.updates(9) == [.partial("chạy"), .partial("chạy các bài"), .final("chạy các bài kiểm tra")])
}

@Test func captureThatNeverStopsTimesOut() async {
    let r = rig(maxCapture: .milliseconds(80))
    await r.hub.input(.voiceStart(voice: 9, purpose: .command, target: 7))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(await r.sent.updates(9) == [.error("Timed out — say it again")])
    #expect(r.engine!.streams[0].cancelled)
}

private let colour = AskQuestion(question: "Which colour?", header: "Colour",
                                 options: ["Red", "Green"].map { AskOption(label: $0, description: "") }, multiSelect: false)
private let fruit = AskQuestion(question: "Which fruits?", header: "Fruits",
                                options: ["Apple", "Banana"].map { AskOption(label: $0, description: "") }, multiSelect: true)

private func askTwo(_ q: RequestQueue) async -> BoardResponse? {
    await q.ask(shape: .question(options: [2, 2], multi: [false, true])) { id in
        [.question(id: id, index: 0, count: 2, project: "p", question: colour),
         .question(id: id, index: 1, count: 2, project: "p", question: fruit)]
    }
}

@Test func otherAnswerIsStoredForTheShownQuestion() async {
    let r = rig(engine: FakeEngine(finals: ["Sầu riêng"]))
    async let answer = askTwo(r.requests)
    await settle()
    let id = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .other(question: 1), target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(9) == [.final("Sầu riêng"), .done("Added as your answer")])
    await r.requests.handle(.answers(id: id, masks: [0b1, 0x80 | 0b1]))
    #expect(await answer == .answers([0b1, 0x81], others: [1: "Sầu riêng"]))
    #expect(r.typer.typed.isEmpty)                                // an answer is never typed
}

@Test func otherForAGoneQuestionFails() async {
    let r = rig(engine: FakeEngine(finals: ["Tím", "Tím"]))
    await r.hub.input(.voiceStart(voice: 8, purpose: .other(question: 0), target: 12345))
    async let answer = askTwo(r.requests)
    await settle()
    let id = await r.sent.questionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .other(question: 0), target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.requests.handle(.answers(id: id, masks: [0b1, 0b1]))    // answered (or gone) before Send
    #expect(await answer == .answers([0b1, 0b1]))
    await r.hub.input(.voiceSend(voice: 9))
    await settle()
    #expect(await r.sent.updates(8) == [.error("The question is no longer on the board")])
    #expect(await r.sent.updates(9).last == .error("The question is no longer on the board"))
}

@Test func denyReasonDeniesTheShownPermission() async {
    let r = rig(engine: FakeEngine(finals: ["dùng pnpm thay vì npm"]))
    async let decision = r.requests.ask(project: "p", tool: "Bash", summary: "npm test")
    await settle()
    let id = await r.sent.permissionIds()[0]
    await r.hub.input(.voiceStart(voice: 9, purpose: .denyReason, target: id))
    await r.hub.input(.voiceStop(voice: 9))
    await r.hub.input(.voiceSend(voice: 9))
    #expect(await decision == .denyWithReason("dùng pnpm thay vì npm"))
    await settle()
    #expect(await r.sent.updates(9) == [.final("dùng pnpm thay vì npm"), .done("Denied with your reason")])
    await r.hub.input(.voiceStart(voice: 10, purpose: .denyReason, target: id))   // no longer shown
    await settle()
    #expect(await r.sent.updates(10) == [.error("The request is no longer on the board")])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && swift test --filter VoiceHubTests 2>&1 | tail -20`
Expected: build errors (`cannot find type 'VoiceStream' in scope`, `cannot find 'VoiceHub' in scope`).

- [ ] **Step 3: The voice hub**

Create `mac/Sources/ClaudeBoardCore/VoiceHub.swift`:

```swift
import Foundation

public enum VoiceConfig {
    /// DictationTranscriber locale. Vietnamese by default; "en_US" would switch voice to English.
    public static let localeIdentifier = "vi_VN"
}

/// Speech to text as the voice hub uses it. The Speech framework engine (macOS 26) lives in the daemon target.
public protocol VoiceEngine: Sendable {
    /// nil when ready (permission granted, model installed); else why voice is unavailable (shown on the board)
    func prepare() async -> String?
    /// Starts one transcription; `onPartial` gets the whole text so far, from any thread
    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream
}

public protocol VoiceStream: AnyObject, Sendable {
    /// 16 kHz mono samples
    func feed(_ samples: [Int16])
    /// Ends the input and returns everything recognised
    func finish() async -> String
    func cancel() async
}

/// One voice capture at a time, from the board's Speak / Other / Deny + why to typed text or an answer.
/// The board streams ADPCM only between voiceStart and voiceStop; the hub answers with partials, one final
/// transcript (VoiceText.forTyping: exactly what Send types) and, after voiceSend for that voice id, done or error.
/// Nothing is typed or answered without voiceSend for the current capture and a non-empty final transcript.
/// Inputs and audio must arrive in board order (the daemon feeds them through one serial stream).
public actor VoiceHub {
    public static let partialInterval: Double = 0.25

    private struct Capture {
        let voice: UInt32
        let purpose: VoicePurpose
        let target: UInt32
        var stream: (any VoiceStream)?
        /// Audio that arrived before the engine was ready
        var pending: [Int16] = []
        var decoder = ADPCMDecoder()
        var stopped = false
        var finishing = false
        var final: String?
        var sending = false
        var lastPartial = ""
        var lastPartialAt = -Double.infinity
    }

    private let engine: (any VoiceEngine)?
    private let typer: any PaneTyping
    private let requests: RequestQueue
    private let target: @Sendable (UInt32) async -> VoiceTarget?
    private let clock: @Sendable () -> Double
    private let maxCapture: Duration
    private let log: @Sendable (String) -> Void
    private var capture: Capture?
    private var engineReady = false

    public init(engine: (any VoiceEngine)?, typer: any PaneTyping, requests: RequestQueue,
                target: @escaping @Sendable (UInt32) async -> VoiceTarget?,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                maxCapture: Duration = .seconds(120),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.engine = engine
        self.typer = typer
        self.requests = requests
        self.target = target
        self.clock = clock
        self.maxCapture = maxCapture
        self.log = log
    }

    public func input(_ input: BoardInput) async {
        switch input {
        case .voiceStart(let voice, let purpose, let target): await start(voice, purpose, target)
        case .voiceStop(let voice): await stop(voice)
        case .voiceCancel(let voice): await cancel(voice)
        case .voiceSend(let voice): await send(voice)
        case .choice, .answers, .mode, .focus: break
        }
    }

    /// One packet from the board's voice characteristic (only used between start and stop)
    public func audio(_ packet: Data) {
        guard var c = capture, !c.stopped else { return }
        let samples = c.decoder.decode(packet)
        if let stream = c.stream { stream.feed(samples) } else { c.pending += samples }
        capture = c
    }

    public func boardDisconnected() async {
        guard let c = capture else { return }
        capture = nil
        await c.stream?.cancel()
    }

    private func post(_ voice: UInt32, _ update: VoiceUpdate) async {
        await requests.post(.voice(id: voice, update))
    }

    private func start(_ voice: UInt32, _ purpose: VoicePurpose, _ targetId: UInt32) async {
        if let old = capture {                      // one capture at a time: a new start replaces the old one
            capture = nil
            await old.stream?.cancel()
        }
        capture = Capture(voice: voice, purpose: purpose, target: targetId)   // audio is buffered from now on
        if let problem = await precheck(purpose, targetId) {
            await fail(voice, problem)
            return
        }
        guard let engine else { return }
        let stream: any VoiceStream
        do {
            stream = try await engine.begin { [weak self] text in
                Task { await self?.partial(voice, text) }
            }
        } catch {
            log("voice \(voice): engine did not start: \(error)")
            await fail(voice, "Speech recognition did not start")
            return
        }
        guard var c = capture, c.voice == voice else {   // cancelled or replaced while the engine started
            await stream.cancel()
            return
        }
        stream.feed(c.pending)
        c.pending = []
        c.stream = stream
        capture = c
        let limit = maxCapture
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.expire(voice)
        }
        if c.stopped { await complete(voice) }
    }

    /// Why this capture cannot be used, checked before the user speaks (Send checks again)
    private func precheck(_ purpose: VoicePurpose, _ id: UInt32) async -> String? {
        guard let engine else { return "Voice needs macOS 26 on the Mac" }
        if !engineReady {
            if let why = await engine.prepare() { return why }   // not cached: permission may be granted later
            engineReady = true
        }
        switch purpose {
        case .command:
            guard let t = await target(id) else { return "Session not found" }
            guard t.state != .ended else { return "This session has ended" }
            guard let pane = t.pane else { return "Open with cb for voice" }
            return await typer.verify(pane)
        case .other(let q):
            guard case .question(let options, _)? = await requests.shownShape(id: id), options.indices.contains(q) else {
                return "The question is no longer on the board"
            }
            return nil
        case .denyReason:
            guard case .permission? = await requests.shownShape(id: id) else { return "The request is no longer on the board" }
            return nil
        }
    }

    private func partial(_ voice: UInt32, _ text: String) async {
        guard var c = capture, c.voice == voice, !c.stopped else { return }
        let now = clock()
        guard text != c.lastPartial, now - c.lastPartialAt >= Self.partialInterval else { return }
        c.lastPartial = text
        c.lastPartialAt = now
        capture = c
        await post(voice, .partial(text))
    }

    private func stop(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.stopped else { return }
        c.stopped = true
        capture = c
        if c.stream != nil { await complete(voice) }   // else start() completes once the engine is ready
    }

    private func complete(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.finishing, let stream = c.stream else { return }
        c.finishing = true
        capture = c
        let raw = await stream.finish()
        guard capture?.voice == voice else { return }   // cancelled or replaced while finishing
        let text = VoiceText.forTyping(raw)
        capture?.final = text
        log("voice \(voice): final transcript, \(text.utf8.count) bytes")
        await post(voice, .final(text))
    }

    private func cancel(_ voice: UInt32) async {
        guard let c = capture, c.voice == voice, !c.sending else { return }
        capture = nil
        await c.stream?.cancel()
    }

    private func send(_ voice: UInt32) async {
        guard var c = capture, c.voice == voice, !c.sending, let text = c.final else { return }   // no final yet: ignored
        guard !text.isEmpty else {
            await fail(voice, "Nothing to send")
            return
        }
        c.sending = true
        capture = c
        let result = await deliver(voice, text, c.purpose, c.target)
        if capture?.voice == voice { capture = nil }
        if let result { await post(voice, result) }
    }

    /// nil: the result already went to the board (deny with reason: before the next request is shown)
    private func deliver(_ voice: UInt32, _ text: String, _ purpose: VoicePurpose, _ id: UInt32) async -> VoiceUpdate? {
        switch purpose {
        case .command:
            guard let t = await target(id) else { return .error("Session not found — nothing sent") }
            // A terminal prompt (permission, question) would take the keystrokes as its answer
            guard t.state != .needsYou else { return .error("Claude is waiting for an answer in the terminal — nothing sent") }
            guard t.state != .ended else { return .error("This session has ended — nothing sent") }
            guard let pane = t.pane else { return .error("Open with cb for voice") }
            switch await typer.type(text, into: pane) {
            case .typed:
                log("voice \(voice): typed \(text.utf8.count) bytes into \(t.project) \(pane.pane)")
                return .done("Sent to \(t.project)")
            case .failed(let why):
                log("voice \(voice): not typed: \(why)")
                return .error(why)
            }
        case .other(let q):
            return await requests.setOther(id: id, question: q, text: text)
                ? .done("Added as your answer") : .error("The question is no longer on the board")
        case .denyReason:
            let notice = BoardMessage.voice(id: voice, .done("Denied with your reason"))
            return await requests.denyWithReason(id: id, message: text, notice: notice)
                ? nil : .error("The request is no longer on the board")
        }
    }

    private func expire(_ voice: UInt32) async {
        guard let c = capture, c.voice == voice, !c.sending else { return }
        await fail(voice, "Timed out — say it again")
    }

    private func fail(_ voice: UInt32, _ why: String) async {
        if let c = capture, c.voice == voice {
            capture = nil
            await c.stream?.cancel()
        }
        log("voice \(voice): \(why)")
        await post(voice, .error(why))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -3`
Expected: no warnings or errors; all tests pass. Run `swift test --filter VoiceHubTests` three times: the timing-based tests (`settle()`, 40 ms) must not flake.

- [ ] **Step 5: Commit**

```bash
git add mac/Sources/ClaudeBoardCore/VoiceHub.swift mac/Tests/ClaudeBoardCoreTests/VoiceHubTests.swift
git commit -F - <<'EOF'
mac: voice hub — one capture at a time, live partials, sanitised final, typed or answered only on Send

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 5: Mac — on-device dictation engine, the voice characteristic and daemon wiring

**Files:**
- Create: `mac/Sources/claude-board/SpeechEngine.swift`
- Modify: `mac/Sources/claude-board/BoardLink.swift`, `mac/Sources/claude-board/main.swift`, `mac/Sources/claude-board/Info.plist`

**Interfaces:**
- Consumes: `VoiceConfig`, `VoiceEngine`, `VoiceStream`, `VoiceHub` (Task 4); `TmuxTyper.system()` (Task 2); `SessionHub.voiceTarget(handle:)` (Task 2); `VoiceText.forTyping` (Task 1); `RequestQueue` (existing).
- Produces: `BoardLink.onVoiceAudio: (@Sendable (Data) -> Void)?`, `BoardLink.voiceChar` (`A7C00013-…`); `claude-board --transcribe <audio file>` (prints `partial: …` lines and `final: …`, exit 0; `voice unavailable: <reason>`, exit 1); daemon log lines `voice ready (vi_VN)` / `voice unavailable: <reason>` at launch, `[ble] voice on` after subscribing.

No unit test can drive CoreBluetooth or the Speech framework; this task is checked by building, by the file self-test on this Mac (Step 5) and end to end in Task 10. The `VoiceHub` logic it wires is covered by Task 4.

- [ ] **Step 1: The engine**

Create `mac/Sources/claude-board/SpeechEngine.swift`:

```swift
@preconcurrency import AVFAudio
import ClaudeBoardCore
import Foundation
import Speech

enum SpeechEngineError: Error { case noAudioFormat }

/// The converter's input block runs synchronously inside convert(); it is marked @Sendable by the SDK
private final class OneShot: @unchecked Sendable { var used = false }

/// Converts PCM buffers to `target` (sample rate, channels, sample type). Not thread-safe: one caller at a time.
final class PCMConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let once = OneShot()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if once.used {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.used = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}

/// On-device dictation with SpeechAnalyzer + DictationTranscriber (the Vietnamese-capable model), one analyzer
/// per capture; the model stays loaded for the daemon's lifetime.
@available(macOS 26.0, *)
final class SpeechEngine: VoiceEngine, @unchecked Sendable {
    private let locale = Locale(identifier: VoiceConfig.localeIdentifier)

    private func makeModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Speech Recognition permission (asked once; denied → the reason is shown on the board), the locale, and
    /// the model (downloaded once through AssetInventory, then offline).
    func prepare() async -> String? {
        let denied = "Allow Speech Recognition for claude-board in System Settings"
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return denied
        case .notDetermined:
            let status = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            if status == .denied || status == .restricted { return denied }
        default:
            break
        }
        guard await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            return "Dictation does not support \(locale.identifier) on this Mac"
        }
        do {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
                try await request.downloadAndInstall()
            }
        } catch {
            return "Speech model not installed: \(error.localizedDescription)"
        }
        return nil
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> any VoiceStream {
        let module = makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechEngineError.noAudioFormat
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
        try await analyzer.start(inputSequence: stream)
        return SpeechStream(analyzer: analyzer, input: input, results: results, converter: PCMConverter(target: format))
    }
}

@available(macOS 26.0, *)
final class SpeechStream: VoiceStream, @unchecked Sendable {
    /// What the board sends: 16 kHz mono Int16
    static let boardFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                           interleaved: true)!

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<String, Never>
    private let converter: PCMConverter   // VoiceHub (an actor) feeds one packet at a time

    init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, results: Task<String, Never>,
         converter: PCMConverter) {
        self.analyzer = analyzer
        self.input = input
        self.results = results
        self.converter = converter
    }

    func feed(_ samples: [Int16]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.boardFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async -> String {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results.value
    }

    func cancel() async {
        input.finish()
        results.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// `claude-board --transcribe FILE`: the same engine on an audio file, without the board. Checks permission and
/// the model on this Mac; prints partials and the final text exactly as voice would type it.
@available(macOS 26.0, *)
func transcribeFile(_ path: String) async -> Int32 {
    let engine = SpeechEngine()
    if let why = await engine.prepare() {
        print("voice unavailable: \(why)")
        return 1
    }
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = PCMConverter(target: SpeechStream.boardFormat)
        let stream = try await engine.begin { print("partial: \($0)") }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            guard let pcm = converter.convert(buffer), let p = pcm.int16ChannelData else { continue }
            stream.feed(Array(UnsafeBufferPointer(start: p[0], count: Int(pcm.frameLength))))
        }
        print("final: \(VoiceText.forTyping(await stream.finish()))")
        return 0
    } catch {
        print("transcribe failed: \(error)")
        return 1
    }
}
```

- [ ] **Step 2: The voice characteristic**

In `mac/Sources/claude-board/BoardLink.swift`:

Add after `static let answerChar = …`:

```swift
    /// Board mic as IMA ADPCM, only between a voice start and its stop (notify, encrypted)
    static let voiceChar = CBUUID(string: "A7C00013-3B2F-4C1E-9D8A-5F6E7D8C9B0A")
```

Add after `var onConnectionChange: …`:

```swift
    var onVoiceAudio: (@Sendable (Data) -> Void)?
```

Add after `private var request: CBCharacteristic?`:

```swift
    private var voice: CBCharacteristic?
```

In `centralManager(_:didConnect:)`, after `subscribeRetried = false`, add `voice = nil`. In `centralManager(_:didDisconnectPeripheral:error:)`, after `request = nil`, add `voice = nil`.

In `peripheral(_:didDiscoverServices:)`, replace `p.discoverCharacteristics([Self.requestChar, Self.answerChar], for: s)` with `p.discoverCharacteristics([Self.requestChar, Self.answerChar, Self.voiceChar], for: s)`.

In `peripheral(_:didDiscoverCharacteristicsFor:error:)`, add inside the loop after `if c.uuid == Self.answerChar { answer = c }`:

```swift
            if c.uuid == Self.voiceChar { voice = c }
```

In `peripheral(_:didUpdateNotificationStateFor:error:)`, insert at the top (before `guard c.uuid == Self.answerChar else { return }`):

```swift
        if c.uuid == Self.voiceChar {
            if let error { log("voice subscribe failed: \(error)") } else { log("voice \(c.isNotifying ? "on" : "off")") }
            return
        }
```

and replace the last three lines of that method (`log("ready")`, `onConnectionChange?(true)`, `}`) with:

```swift
        log("ready")
        onConnectionChange?(true)
        // Voice rides the same encrypted link; subscribing costs nothing until the board records
        if let voice { p.setNotifyValue(true, for: voice) } else { log("board has no voice characteristic (old firmware)") }
    }
```

Replace `peripheral(_:didUpdateValueFor:error:)` with:

```swift
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        if c.uuid == Self.voiceChar {
            onVoiceAudio?(v)
        } else if c.uuid == Self.answerChar, let input = BoardInput.decode(v) {
            onInput?(input)
        }
    }
```

(Both characteristics notify on `queue`, in board order: a stop input never overtakes the last audio packet.)

- [ ] **Step 3: Daemon wiring**

In `mac/Sources/claude-board/main.swift`:

Insert right after `func log(_ s: String) { … }`:

```swift
// Self-test: claude-board --transcribe FILE (no board, no socket)
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--transcribe" {
    if #available(macOS 26.0, *) {
        let path = CommandLine.arguments[2]
        Task { exit(await transcribeFile(path)) }
        dispatchMain()
    } else {
        print("voice needs macOS 26")
        exit(1)
    }
}
```

Insert right after `Task { for await event in hubEvents { await event() } }`:

```swift
// Voice: on-device dictation (macOS 26), typing into verified cb panes. Voice inputs and audio packets reach the
// hub in board order through one serial stream (the stop input follows the last packet).
let voiceEngine: (any VoiceEngine)? = {
    if #available(macOS 26.0, *) { return SpeechEngine() }
    return nil
}()
let voice = VoiceHub(engine: voiceEngine, typer: TmuxTyper.system(), requests: requests,
                     target: { await hub.voiceTarget(handle: $0) }, log: log)
let (voiceEvents, voiceFeed) = AsyncStream<@Sendable () async -> Void>.makeStream()
Task { for await event in voiceEvents { await event() } }
board.onVoiceAudio = { packet in voiceFeed.yield { await voice.audio(packet) } }
if let voiceEngine {
    // Asks for Speech Recognition once and installs the model ahead of the first capture
    Task {
        if let why = await voiceEngine.prepare() { log("voice unavailable: \(why)") }
        else { log("voice ready (\(VoiceConfig.localeIdentifier))") }
    }
} else {
    log("voice unavailable: needs macOS 26")
}
```

In `board.onInput`, replace the branch added in Task 1

```swift
    case .voiceStart, .voiceStop, .voiceCancel, .voiceSend:
        break
```

with

```swift
    case .voiceStart, .voiceStop, .voiceCancel, .voiceSend:   // voice captures (Speak, Other, Deny + why)
        voiceFeed.yield { await voice.input(input) }
```

In `board.onConnectionChange`, replace

```swift
    } else {
        Task { await requests.boardDisconnected() }
    }
```

with

```swift
    } else {
        Task { await requests.boardDisconnected() }
        voiceFeed.yield { await voice.boardDisconnected() }
    }
```

In `mac/Sources/claude-board/Info.plist`, add after the `NSBluetoothAlwaysUsageDescription` string:

```xml
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>claude-board transcribes what you say into the board, on this Mac, to type voice commands into Claude Code.</string>
```

- [ ] **Step 4: Build and test**

Run: `cd mac && swift build 2>&1 | grep -E "warning|error" ; swift test 2>&1 | tail -1 && plutil -lint Sources/claude-board/Info.plist`
Expected: no warnings or errors; all tests pass; `Info.plist: OK`.

- [ ] **Step 5: Self-test the engine on this Mac**

```bash
cd mac && swift build -c release 2>&1 | tail -1
say -v Linh -o /tmp/cb-vi.aiff "Xin chào, hãy chạy các bài kiểm tra"
./.build/release/claude-board --transcribe /tmp/cb-vi.aiff
```

Expected: some `partial: …` lines, then `final: Xin chào hãy chạy các bài kiểm tra` (verified by the plan author on this Mac with these exact code blocks: `vi_VN` is supported and installed, Speech Recognition was already authorized for the terminal; punctuation may differ, the words must match). The first run may download the Vietnamese dictation model (minutes, needs network) and macOS may show a Speech Recognition permission prompt (attributed to Terminal or claude-board): **this needs the user** — ask them to allow it, then rerun. Outcomes to record in the task report: `voice unavailable: Dictation does not support vi_VN on this Mac` → stop and report (the spec's default language is not available); `voice unavailable: Allow Speech Recognition…` → the user enables it in System Settings → Privacy & Security → Speech Recognition and reruns; `transcribe failed: …` → report the error verbatim. If the voice `Linh` is missing (`say -v '?' | grep vi_VN` is empty), record a sentence with QuickTime instead (ask the user) and transcribe that file.

- [ ] **Step 6: Commit**

```bash
git add mac/Sources/claude-board
git commit -F - <<'EOF'
mac: on-device dictation engine (DictationTranscriber vi_VN), board voice characteristic, voice hub wiring

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 6: Mac — the `cb` launcher and its installation

**Files:**
- Create: `mac/cb`, `mac/test_cb.py`
- Modify: `mac/claude_settings.py` (`link-cb` / `unlink-cb`), `mac/test_claude_settings.py`, `mac/install.sh`, `mac/uninstall.sh`

**Interfaces:**
- Consumes: `TmuxTyper.mark` = `@claude_board` (Task 2: the daemon types only into panes where this pane option is `1`).
- Produces: `cb [claude arguments…]` installed as `~/.claude-board/bin/cb` (and `~/.local/bin/cb` when that directory exists); `python3 claude_settings.py link-cb TARGET LINK_DIR` / `unlink-cb TARGET LINK_DIR`; test hooks `CB_TMUX`, `CB_NO_ATTACH=1` (prints the pane id instead of attaching), installer override `LOCAL_BIN`.

`cb` runs Claude Code as the pane's own process (`exec`), so the pane's `pane_pid` is Claude Code itself (or the shell that `cb` replaced with it); that is what the daemon's ancestry check (Task 2) expects.

- [ ] **Step 1: Write the failing tests**

Create `mac/test_cb.py`:

```python
# mac/test_cb.py — run: cd mac && python3 -m unittest test_cb -v
# Uses a private tmux server (TMUX_TMPDIR) and a fake `claude` that records its arguments.
import os
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CB = os.path.join(HERE, "cb")
TMUX = shutil.which("tmux") or next(
    (p for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.path.exists(p)), None)

FAKE_CLAUDE = """#!/bin/bash
{ echo "$#"; for a in "$@"; do printf '%s\\n' "$a"; done; } > "$CB_TEST_OUT"
exec sleep 60
"""


@unittest.skipUnless(TMUX, "tmux is not installed")
class CbTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cbt")
        self.sock_dir = tempfile.mkdtemp(prefix="cbs", dir="/tmp")   # Unix socket paths are short
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        claude = os.path.join(bindir, "claude")
        with open(claude, "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(claude, 0o755)
        self.out = os.path.join(self.tmp, "args")
        self.env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": self.tmp, "TMUX_TMPDIR": self.sock_dir,
                    "CB_TMUX": TMUX, "CB_NO_ATTACH": "1", "CB_TEST_OUT": self.out, "TERM": "xterm-256color"}

    def tearDown(self):
        subprocess.run([TMUX, "kill-server"], env=self.env, capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)
        shutil.rmtree(self.sock_dir, ignore_errors=True)

    def project(self, name):
        d = os.path.join(self.tmp, name)
        os.makedirs(d)
        return d

    def cb(self, cwd, *args):
        r = subprocess.run([CB, *args], cwd=cwd, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def tmux(self, *args):
        return subprocess.run([TMUX, *args], env=self.env, capture_output=True, text=True, timeout=10).stdout.strip()

    def claude_args(self):
        for _ in range(100):
            if os.path.exists(self.out):
                lines = open(self.out).read().splitlines()
                if lines and len(lines) == int(lines[0]) + 1:
                    return lines[1:]
            time.sleep(0.05)
        self.fail("claude was not started")

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_name}").splitlines()

    def test_starts_claude_in_a_marked_session_named_after_the_directory(self):
        pane = self.cb(self.project("esp32-translator"), "--resume", "a b")
        self.assertTrue(pane.startswith("%"), pane)
        self.assertEqual(self.claude_args(), ["--resume", "a b"])
        self.assertEqual(self.sessions(), ["esp32-translator"])
        self.assertEqual(self.tmux("show-options", "-p", "-v", "-t", pane, "@claude_board"), "1")

    def test_no_arguments_still_runs_claude(self):
        self.cb(self.project("plain"))
        self.assertEqual(self.claude_args(), [])

    def test_second_run_attaches_to_the_same_session(self):
        d = self.project("api")
        first = self.cb(d)
        self.claude_args()
        self.assertEqual(self.cb(d), first)
        self.assertEqual(self.sessions(), ["api"])

    def test_odd_directory_names_are_sanitised(self):
        self.cb(self.project("my.proj:x"))
        self.claude_args()
        self.assertEqual(self.sessions(), ["my_proj_x"])

    def test_inside_tmux_marks_this_pane_and_runs_claude_here(self):
        pane = self.tmux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "host", "sleep 60")
        sock = self.tmux("display-message", "-p", "-t", pane, "#{socket_path}")
        env = dict(self.env, TMUX=sock + ",1,0", TMUX_PANE=pane)
        p = subprocess.Popen([CB, "-c"], cwd=self.project("inner"), env=env)
        try:
            self.assertEqual(self.claude_args(), ["-c"])
            self.assertEqual(self.tmux("show-options", "-p", "-v", "-t", pane, "@claude_board"), "1")
            self.assertEqual(self.sessions(), ["host"])            # no new session
        finally:
            p.kill()
            p.wait()

    def test_missing_claude_is_an_error(self):
        env = dict(self.env, PATH="/usr/bin:/bin")
        r = subprocess.run([CB], cwd=self.project("x"), env=env, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("claude not found", r.stderr)


if __name__ == "__main__":
    unittest.main()
```

Append to `mac/test_claude_settings.py` (before any `if __name__` block, or at the end if there is none):

```python
class LinkCbTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.target = os.path.join(self.dir, "bin", "cb")
        os.makedirs(os.path.dirname(self.target))
        open(self.target, "w").close()
        self.links = os.path.join(self.dir, "local-bin")
        self.link = os.path.join(self.links, "cb")

    def test_no_link_directory_no_link(self):
        run("link-cb", self.target, self.links)
        self.assertFalse(os.path.lexists(self.link))

    def test_links_once_and_unlinks(self):
        os.makedirs(self.links)
        run("link-cb", self.target, self.links)
        run("link-cb", self.target, self.links)           # again: still the same link
        self.assertEqual(os.readlink(self.link), self.target)
        run("unlink-cb", self.target, self.links)
        self.assertFalse(os.path.lexists(self.link))

    def test_never_replaces_or_removes_another_cb(self):
        os.makedirs(self.links)
        with open(self.link, "w") as f:
            f.write("#!/bin/sh\necho mine\n")
        run("link-cb", self.target, self.links)
        run("unlink-cb", self.target, self.links)
        with open(self.link) as f:
            self.assertIn("mine", f.read())
        os.unlink(self.link)
        os.symlink("/elsewhere/cb", self.link)
        run("link-cb", self.target, self.links)
        run("unlink-cb", self.target, self.links)
        self.assertEqual(os.readlink(self.link), "/elsewhere/cb")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mac && python3 -m unittest test_cb test_claude_settings -v 2>&1 | tail -15`
Expected: the `CbTests` fail (`No such file or directory: …/mac/cb`) and the `LinkCbTests` fail (`claude_settings.py` exits non-zero for the unknown modes).

- [ ] **Step 3: The launcher**

Create `mac/cb` (then `chmod 755 mac/cb`):

```bash
#!/bin/bash
# cb — start Claude Code inside tmux so the claude-board daemon can type voice commands into it.
#   cb [claude arguments...]
# Outside tmux: runs `claude "$@"` in a tmux session named after the current directory, or attaches to that
# session if it already exists (the arguments are then not used). Inside tmux: runs claude in the current pane.
# Either way the pane gets the option @claude_board=1: the daemon only types into marked panes that still run
# the session's own Claude Code. Remote Control and everything else work as usual.
# Test hooks: CB_TMUX (tmux binary), CB_NO_ATTACH=1 (print the pane id instead of attaching)
set -euo pipefail

TMUX_BIN=${CB_TMUX:-$(command -v tmux || true)}
for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
  if [ -z "$TMUX_BIN" ] && [ -x "$candidate" ]; then TMUX_BIN=$candidate; fi
done
[ -n "$TMUX_BIN" ] || { echo "cb: tmux not found (brew install tmux)" >&2; exit 1; }
CLAUDE_BIN=$(command -v claude || true)
[ -n "$CLAUDE_BIN" ] || { echo "cb: claude not found in PATH" >&2; exit 1; }

if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  "$TMUX_BIN" set-option -p -t "$TMUX_PANE" @claude_board 1
  exec "$CLAUDE_BIN" "$@"
fi

# tmux session names cannot contain "." or ":"
name=$(printf '%s' "$(basename "$PWD")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
[ -n "$name" ] || name=claude
if "$TMUX_BIN" has-session -t "=$name" 2>/dev/null; then
  pane=$("$TMUX_BIN" display-message -p -t "=$name:" '#{pane_id}')
else
  # One argument would go through `sh -c`: exec the quoted path so the pane process is claude itself
  if [ $# -eq 0 ]; then cmd=("$(printf 'exec %q' "$CLAUDE_BIN")"); else cmd=("$CLAUDE_BIN" "$@"); fi
  pane=$("$TMUX_BIN" new-session -d -P -F '#{pane_id}' -s "$name" -c "$PWD" -e "PATH=$PATH" -- "${cmd[@]}")
  "$TMUX_BIN" set-option -p -t "$pane" @claude_board 1
fi
if [ "${CB_NO_ATTACH:-0}" = 1 ]; then
  echo "$pane"
  exit 0
fi
exec "$TMUX_BIN" attach-session -t "=$name"
```

- [ ] **Step 4: Install and uninstall**

In `mac/claude_settings.py`:

Replace the usage lines of the module docstring with:

```
usage: claude_settings.py install   SETTINGS HOOK_PATH
       claude_settings.py uninstall SETTINGS
       claude_settings.py plist TEMPLATE OUT BIN HOME
       claude_settings.py link-cb   TARGET LINK_DIR    (symlink LINK_DIR/cb -> TARGET, never over another cb)
       claude_settings.py unlink-cb TARGET LINK_DIR    (remove LINK_DIR/cb only if it points to TARGET)
```

Add before `def main(argv):`:

```python
def link_cb(target, link_dir):
    """Symlinks LINK_DIR/cb to TARGET when LINK_DIR exists and holds no other cb. Returns what happened."""
    link = os.path.join(link_dir, "cb")
    if not os.path.isdir(link_dir):
        return "cb: %s does not exist; run %s, or add %s to PATH" % (link_dir, target, os.path.dirname(target))
    if os.path.islink(link):
        if os.readlink(link) == target:
            return "cb: %s already links to %s" % (link, target)
        return "cb: %s points elsewhere (%s); left untouched" % (link, os.readlink(link))
    if os.path.exists(link):
        return "cb: %s already exists; left untouched" % link
    os.symlink(target, link)
    return "cb: linked %s -> %s" % (link, target)


def unlink_cb(target, link_dir):
    link = os.path.join(link_dir, "cb")
    if os.path.islink(link) and os.readlink(link) == target:
        os.unlink(link)
        return "cb: removed %s" % link
    return None
```

In `main`, add right after `mode = argv[1]`:

```python
    if mode in ("link-cb", "unlink-cb"):
        msg = (link_cb if mode == "link-cb" else unlink_cb)(argv[2], argv[3])
        if msg:
            print(msg)
        return
```

In `mac/install.sh`, change the overrides comment to `# Test overrides: BIN, CLAUDE_SETTINGS, LOCAL_BIN, CLAUDE_BOARD_SKIP_LAUNCHD=1` and add after `install_bin claude-board-hook`:

```bash
# cb: starts claude inside a marked tmux pane so the board can type voice commands into it
tmp="$BIN/.cb.tmp.$$"
cp cb "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$BIN/cb"
python3 claude_settings.py link-cb "$BIN/cb" "${LOCAL_BIN:-$HOME/.local/bin}"
```

In `mac/uninstall.sh`, change the overrides comment the same way, and replace `rm -f "$BIN/claude-board" "$BIN/claude-board-hook"` with:

```bash
python3 claude_settings.py unlink-cb "$BIN/cb" "${LOCAL_BIN:-$HOME/.local/bin}"
rm -f "$BIN/claude-board" "$BIN/claude-board-hook" "$BIN/cb"
```

- [ ] **Step 5: Run the tests**

Run: `cd mac && chmod 755 cb && bash -n cb && python3 -m unittest test_cb test_claude_settings -v 2>&1 | tail -5`
Expected: `OK` (no skips: tmux is installed on this Mac). Then check the installer end to end without touching the real setup:

```bash
cd mac && T=$(mktemp -d) && mkdir -p "$T/local" && BIN="$T/bin" CLAUDE_SETTINGS="$T/settings.json" LOCAL_BIN="$T/local" \
  CLAUDE_BOARD_SKIP_LAUNCHD=1 bash install.sh | tail -3 && ls -l "$T/local/cb" "$T/bin/cb" && \
  BIN="$T/bin" CLAUDE_SETTINGS="$T/settings.json" LOCAL_BIN="$T/local" CLAUDE_BOARD_SKIP_LAUNCHD=1 bash uninstall.sh && ls "$T/local" "$T/bin" 2>&1 | head -3
```

Expected: `cb: linked …/local/cb -> …/bin/cb` and `claude-board installed.`; the link and an executable `cb`; after uninstall `cb: removed …`, `claude-board uninstalled.` and both directories empty or gone.

- [ ] **Step 6: Commit**

```bash
git add mac/cb mac/test_cb.py mac/claude_settings.py mac/test_claude_settings.py mac/install.sh mac/uninstall.sh
git commit -F - <<'EOF'
mac: cb launcher (claude in a marked tmux pane named after the project) installed with an optional ~/.local/bin link

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 7: Firmware — voice protocol, the capture model and the Other answer model (host-tested)

**Files:**
- Modify: `firmware/main/claude_proto.h`, `firmware/main/claude_proto.c` (kind 8, voice encoders, session voice flag), `firmware/main/sessions.c:126-135` (`sessions_set_focus` keeps the voice flag), `firmware/main/question.h`, `firmware/main/question.c` (spoken Other answer, mask bit 7), `firmware/main/CMakeLists.txt`
- Create: `firmware/main/voice.h`, `firmware/main/voice.c`
- Test: `firmware/test/test_claude_proto.c`, `firmware/test/test_sessions.c`, `firmware/test/test_question.c`, `firmware/test/test_voice.c` (new)

**Interfaces:**
- Consumes: the wire format in "Protocol" above (same vectors as Task 1).
- Produces (used by Tasks 8–9):
  - `CLAUDE_VOICE = 8` (kind), `CLAUDE_VOICE_TEXT_MAX 300`, `CLAUDE_VOICE_PARTIAL 'p'`, `CLAUDE_VOICE_FINAL 'f'`, `CLAUDE_VOICE_ERROR 'x'`, `CLAUDE_VOICE_DONE 'k'`, `claude_voice_t { uint32_t id; char what; char text[CLAUDE_TEXT_MAX + 1]; }`, `bool claude_parse_voice(const claude_msg_t *m, claude_voice_t *out);`
  - `CLAUDE_SESSION_VOICE 0x04`
  - `CLAUDE_INPUT_VOICE_START 0x30`, `CLAUDE_INPUT_VOICE_STOP 0x31`, `CLAUDE_INPUT_VOICE_CANCEL 0x32`, `CLAUDE_INPUT_VOICE_SEND 0x33`, `CLAUDE_VOICE_FOR_COMMAND 0`, `CLAUDE_VOICE_FOR_OTHER 1`, `CLAUDE_VOICE_FOR_DENY 2`
  - `size_t claude_encode_voice_start(uint32_t voice, uint8_t purpose, uint8_t question, uint32_t target, uint8_t out[CLAUDE_INPUT_MAX]);` (10 bytes or 0), `size_t claude_encode_voice(uint32_t voice, uint8_t code, uint8_t out[CLAUDE_INPUT_MAX]);` (stop / cancel / send: 5 bytes or 0)
  - `voice.h`: `VOICE_START_FRAMES 2`, `VOICE_SILENCE_FRAMES 75`, `VOICE_NOTHING_FRAMES 250`, `VOICE_MAX_FRAMES 1500`; `voice_vad_t`, `voice_vad_result_t { VOICE_VAD_GO, VOICE_VAD_SILENCE, VOICE_VAD_NOTHING, VOICE_VAD_MAX }`, `void voice_vad_init(voice_vad_t *v);`, `voice_vad_result_t voice_vad_step(voice_vad_t *v, float db);`
  - `voice.h` flow: `voice_state_t { VOICE_IDLE, VOICE_RECORDING, VOICE_FINISHING, VOICE_CONFIRM, VOICE_SENDING, VOICE_RESULT }`, `voice_flow_t { voice_state_t state; uint8_t purpose; uint8_t question; uint32_t target; uint32_t id; bool ok; bool empty; char text[CLAUDE_TEXT_MAX + 1]; char note[CLAUDE_TEXT_MAX + 1]; }`, `void voice_reset(voice_flow_t *f);`, `bool voice_active(const voice_flow_t *f);` (recording…sending), `size_t voice_begin(voice_flow_t *f, uint32_t id, uint8_t purpose, uint8_t question, uint32_t target, uint8_t out[CLAUDE_INPUT_MAX]);`, `bool voice_captured(voice_flow_t *f, uint32_t id);`, `size_t voice_cancel(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);`, `size_t voice_send(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);`, `bool voice_on_update(voice_flow_t *f, const claude_voice_t *u);`, `void voice_fail(voice_flow_t *f, const char *note);`
  - `question.h`: `QUESTION_OTHER 7` (the `question_tap` option for the spoken Other answer), `QUESTION_OTHER_BIT 0x80`, `question_set_t.other[CLAUDE_Q_MAX][CLAUDE_VOICE_TEXT_MAX + 1]` ("" = nothing spoken for that page), `void question_set_other(question_set_t *s, uint8_t page, const char *text);`

- [ ] **Step 1: Write the failing tests**

In `firmware/test/test_claude_proto.c`, in `session_rejects_bad_rows`, replace `"w 1 2 0 9\np\nl", "w 1 2 7\np\nl", "w1 2 3 0\np\nl",` with `"w 1 2 0 9\np\nl", "w 1 2 8\np\nl", "w1 2 3 0\np\nl",` (flags 7 is valid now: focused + unseen + voice). Add before `int main(void)`:

```c
static void session_voice_flag_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_SESSION, 5, "w 1759555200 1759555260 5\ndự-án\nDone.");
    claude_session_t s;
    assert(claude_parse_session(&m, &s));
    assert(s.flags == (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_VOICE));
    claude_msg_t all = msg(CLAUDE_SESSION, 5, "i 1 2 7\np\nl");
    assert(claude_parse_session(&all, &s) && s.flags == 7);
}

static void voice_message_parses(void)
{
    claude_msg_t m = from_wire(CLAUDE_VOICE, 9, "f\nXin chào");
    claude_voice_t v;
    assert(m.kind == CLAUDE_VOICE && claude_parse_voice(&m, &v));
    assert(v.id == 9 && v.what == CLAUDE_VOICE_FINAL && strcmp(v.text, "Xin chào") == 0);
    claude_msg_t empty = msg(CLAUDE_VOICE, 9, "f\n");
    assert(claude_parse_voice(&empty, &v) && v.what == CLAUDE_VOICE_FINAL && v.text[0] == '\0');
    const char *good[] = { "p\nchạy", "x\nOpen with cb for voice", "k\nSent to esp32" };
    const char what[] = { CLAUDE_VOICE_PARTIAL, CLAUDE_VOICE_ERROR, CLAUDE_VOICE_DONE };
    for (int i = 0; i < 3; i++) {
        claude_msg_t g = msg(CLAUDE_VOICE, 9, good[i]);
        assert(claude_parse_voice(&g, &v) && v.what == what[i] && strcmp(v.text, strchr(good[i], '\n') + 1) == 0);
    }
    const char *bad[] = { "", "f", "fx\nabc", "q\nabc", "f abc" };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        claude_msg_t b = msg(CLAUDE_VOICE, 9, bad[i]);
        assert(!claude_parse_voice(&b, &v));
    }
    claude_msg_t zero = msg(CLAUDE_VOICE, 0, "f\nx");
    assert(!claude_parse_voice(&zero, &v));
    claude_msg_t other = msg(CLAUDE_FINISHED, 9, "f\nx");
    assert(!claude_parse_voice(&other, &v));
}

static void voice_encoders_match_the_mac(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(claude_encode_voice_start(0x0A0B0C0D, CLAUDE_VOICE_FOR_OTHER, 2, 0x01020304, out) == 10);
    const uint8_t want_other[10] = { 0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01 };
    assert(memcmp(out, want_other, 10) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 10);
    const uint8_t want_command[10] = { 9, 0, 0, 0, 0x30, 0x00, 5, 0, 0, 0 };
    assert(memcmp(out, want_command, 10) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_DENY, 0, 7, out) == 10 && out[5] == 0x02);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_STOP, out) == 5);
    const uint8_t want_stop[5] = { 9, 0, 0, 0, 0x31 };
    assert(memcmp(out, want_stop, 5) == 0);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_CANCEL, out) == 5 && out[4] == 0x32);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_SEND, out) == 5 && out[4] == 0x33);
    /* Other answers ride on the unchanged answers input: bit 7 */
    uint8_t masks[2] = { 0x80, 0x05 };
    assert(claude_encode_answers(0x01020304, masks, 2, out) == 8);
    const uint8_t want_answers[8] = { 0x04, 0x03, 0x02, 0x01, 0x10, 0x02, 0x80, 0x05 };
    assert(memcmp(out, want_answers, 8) == 0);
}

static void voice_encoders_refuse_bad_input(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(claude_encode_voice_start(0, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);          /* voice 0 */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 0, 0, out) == 0);          /* target 0 */
    assert(claude_encode_voice_start(9, 3, 0, 5, out) == 0);                                 /* purpose */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_COMMAND, 1, 5, out) == 0);          /* question */
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_DENY, 1, 5, out) == 0);
    assert(claude_encode_voice_start(9, CLAUDE_VOICE_FOR_OTHER, CLAUDE_Q_MAX, 5, out) == 0);
    assert(claude_encode_voice(0, CLAUDE_INPUT_VOICE_STOP, out) == 0);
    assert(claude_encode_voice(9, CLAUDE_INPUT_VOICE_START, out) == 0);                      /* not 5 bytes */
    assert(claude_encode_voice(9, 0x34, out) == 0);
}
```

and call `session_voice_flag_parses(); voice_message_parses(); voice_encoders_match_the_mac(); voice_encoders_refuse_bad_input();` from `main` before the `puts`.

In `firmware/test/test_sessions.c`, add before `int main(void)`:

```c
static void focus_keeps_the_voice_flag(void)
{
    sessions_t s;
    sessions_clear(&s);
    claude_session_t a = row(1, CLAUDE_STATE_IDLE, 10, CLAUDE_SESSION_UNSEEN | CLAUDE_SESSION_VOICE, "a");
    claude_session_t b = row(2, CLAUDE_STATE_IDLE, 20, CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_VOICE, "b");
    sessions_upsert(&s, &a);
    sessions_upsert(&s, &b);
    sessions_set_focus(&s, 1);
    const claude_session_t *f = sessions_focused(&s);
    assert(f != NULL && f->handle == 1 && f->flags == (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_VOICE));
    sessions_set_focus(&s, 2);
    for (int i = 0; i < s.n; i++) {
        assert(s.rows[i].flags & CLAUDE_SESSION_VOICE);   /* moving the focus never drops voice */
    }
}
```

and call `focus_keeps_the_voice_flag();` from `main` before the `puts`.

In `firmware/test/test_question.c`, add before `int main(void)`:

```c
static void other_needs_a_spoken_text(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 7, &p0);
    question_add(&s, 7, &p1);
    question_tap(&s, QUESTION_OTHER);                  /* nothing spoken yet: no selection */
    assert(!question_page_answered(&s, 0));
    question_set_other(&s, 0, "Tím than");             /* Use on the confirm screen: stored and selected */
    assert(s.mask[0] == QUESTION_OTHER_BIT && strcmp(s.other[0], "Tím than") == 0);
    question_tap(&s, 1);                               /* single-select: an option replaces Other */
    assert(s.mask[0] == 0x02);
    question_tap(&s, QUESTION_OTHER);                  /* and Other replaces the option; the text stays */
    assert(s.mask[0] == QUESTION_OTHER_BIT);
    question_set_other(&s, 0, "");                     /* removed */
    assert(s.mask[0] == 0 && s.other[0][0] == '\0');
}

static void other_adds_on_multi_select_and_is_encoded(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 2, false, 2), p1 = page(1, 2, true, 3);
    question_add(&s, 7, &p0);
    question_add(&s, 7, &p1);
    question_tap(&s, 1);
    question_next(&s);
    question_tap(&s, 0);
    question_set_other(&s, 1, "Sầu riêng");
    assert(s.mask[1] == (QUESTION_OTHER_BIT | 0x01));
    question_tap(&s, QUESTION_OTHER);                  /* multi-select: untick Other, keep the option */
    assert(s.mask[1] == 0x01);
    question_tap(&s, QUESTION_OTHER);
    uint8_t out[CLAUDE_INPUT_MAX];
    assert(question_encode(&s, out) == 8 && out[6] == 0x02 && out[7] == (QUESTION_OTHER_BIT | 0x01));
}

static void a_resent_page_loses_its_other(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 1, false, 2);
    question_add(&s, 7, &p0);
    question_set_other(&s, 0, "Tím");
    question_add(&s, 7, &p0);                          /* the Mac resent the page */
    assert(s.mask[0] == 0 && s.other[0][0] == '\0');
}

static void long_other_is_cut_utf8_safe(void)
{
    question_reset(&s);
    claude_question_t p0 = page(0, 1, false, 2);
    question_add(&s, 7, &p0);
    char t[CLAUDE_TEXT_MAX + 1] = "";
    for (int i = 0; i < 120; i++) {
        strcat(t, "ữ");                                /* 3 bytes each: 360 bytes */
    }
    question_set_other(&s, 0, t);
    assert(strlen(s.other[0]) == CLAUDE_VOICE_TEXT_MAX);   /* 100 whole characters */
    question_set_other(&s, 3, "x");                    /* no such page: ignored */
}
```

and call `other_needs_a_spoken_text(); other_adds_on_multi_select_and_is_encoded(); a_resent_page_loses_its_other(); long_other_is_cut_utf8_safe();` from `main` before the `puts`.

Create `firmware/test/test_voice.c`:

```c
// firmware/test/test_voice.c — build: cc -Wall -Wextra -Werror -I../main -o /tmp/test_voice test_voice.c ../main/voice.c ../main/claude_proto.c && /tmp/test_voice
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "voice.h"

/* Feeds n frames at db; the capture may only end on the last one */
static voice_vad_result_t feed(voice_vad_t *v, float db, int n)
{
    voice_vad_result_t r = VOICE_VAD_GO;
    for (int i = 0; i < n; i++) {
        r = voice_vad_step(v, db);
        assert(r == VOICE_VAD_GO || i == n - 1);
    }
    return r;
}

static void vad_ends_after_silence_following_speech(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -70.0f, 10) == VOICE_VAD_GO);                      /* room before speaking */
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);                      /* 400 ms of speech */
    assert(feed(&v, -70.0f, VOICE_SILENCE_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -70.0f) == VOICE_VAD_SILENCE);           /* 1.5 s of silence */
}

static void vad_pause_inside_a_sentence_keeps_going(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);
    assert(feed(&v, -70.0f, 50) == VOICE_VAD_GO);                      /* 1 s pause */
    assert(feed(&v, -30.0f, 20) == VOICE_VAD_GO);
    assert(feed(&v, -70.0f, VOICE_SILENCE_FRAMES) == VOICE_VAD_SILENCE);
}

static void vad_ends_when_nothing_is_said(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -70.0f, VOICE_NOTHING_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -70.0f) == VOICE_VAD_NOTHING);
}

static void vad_click_is_not_speech(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(voice_vad_step(&v, -20.0f) == VOICE_VAD_GO);                /* one loud frame: a tap on the case */
    assert(feed(&v, -70.0f, VOICE_NOTHING_FRAMES - 1) == VOICE_VAD_NOTHING);
}

static void vad_caps_a_long_capture(void)
{
    voice_vad_t v;
    voice_vad_init(&v);
    assert(feed(&v, -30.0f, VOICE_MAX_FRAMES - 1) == VOICE_VAD_GO);
    assert(voice_vad_step(&v, -30.0f) == VOICE_VAD_MAX);
}

static voice_flow_t f;   /* about 0.8 KB: static, as on the board */

static claude_voice_t update(uint32_t id, char what, const char *text)
{
    claude_voice_t u;
    memset(&u, 0, sizeof u);
    u.id = id;
    u.what = what;
    snprintf(u.text, sizeof u.text, "%s", text);
    return u;
}

static void begin_encodes_the_start(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    assert(voice_begin(&f, 0x0A0B0C0D, CLAUDE_VOICE_FOR_OTHER, 2, 0x01020304, out) == 10);
    const uint8_t want[10] = { 0x0d, 0x0c, 0x0b, 0x0a, 0x30, 0x21, 0x04, 0x03, 0x02, 0x01 };
    assert(memcmp(out, want, 10) == 0);
    assert(f.state == VOICE_RECORDING && voice_active(&f));
    assert(f.id == 0x0A0B0C0D && f.purpose == CLAUDE_VOICE_FOR_OTHER && f.question == 2 && f.target == 0x01020304);
    assert(voice_begin(&f, 10, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);    /* one capture at a time */
    voice_reset(&f);
    assert(voice_begin(&f, 0, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 0);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 0, out) == 0);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 1, 5, out) == 0);
    assert(f.state == VOICE_IDLE && !voice_active(&f));
}

static void command_round_trip(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    assert(voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out) == 10);
    claude_voice_t u = update(9, CLAUDE_VOICE_PARTIAL, "chạy các");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RECORDING && strcmp(f.text, "chạy các") == 0);
    assert(voice_send(&f, out) == 0);                                  /* nothing to send while recording */
    assert(!voice_captured(&f, 10));
    assert(voice_captured(&f, 9) && f.state == VOICE_FINISHING);
    u = update(9, CLAUDE_VOICE_FINAL, "chạy các bài kiểm tra");
    assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM && !f.empty);
    assert(strcmp(f.text, "chạy các bài kiểm tra") == 0);
    u = update(9, CLAUDE_VOICE_PARTIAL, "late");                     /* never changes what Send sends */
    assert(!voice_on_update(&f, &u) && strcmp(f.text, "chạy các bài kiểm tra") == 0);
    assert(voice_send(&f, out) == 5);
    const uint8_t want_send[5] = { 9, 0, 0, 0, 0x33 };
    assert(memcmp(out, want_send, 5) == 0 && f.state == VOICE_SENDING);
    assert(voice_send(&f, out) == 0);                                  /* one Send only */
    u = update(9, CLAUDE_VOICE_DONE, "Sent to esp32");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RESULT && f.ok && strcmp(f.note, "Sent to esp32") == 0);
    assert(!voice_active(&f));
    assert(voice_cancel(&f, out) == 0 && f.state == VOICE_IDLE);       /* closing a result sends nothing */
}

static void final_may_arrive_before_the_capture_callback(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "xin chào");
    assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM);
    assert(!voice_captured(&f, 9) && f.state == VOICE_CONFIRM);
}

static void empty_final_cannot_be_sent(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    const char *empties[] = { "", "   " };
    for (int i = 0; i < 2; i++) {
        voice_reset(&f);
        voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
        voice_captured(&f, 9);
        claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, empties[i]);
        assert(voice_on_update(&f, &u) && f.state == VOICE_CONFIRM && f.empty);
        assert(voice_send(&f, out) == 0 && f.state == VOICE_CONFIRM);
    }
}

static void errors_end_the_capture(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_ERROR, "Open with cb for voice");
    assert(voice_on_update(&f, &u) && f.state == VOICE_RESULT && !f.ok);
    assert(strcmp(f.note, "Open with cb for voice") == 0 && !voice_active(&f));
    u = update(9, CLAUDE_VOICE_DONE, "late");
    assert(!voice_on_update(&f, &u));
}

static void done_needs_a_send(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "x");
    voice_on_update(&f, &u);
    u = update(9, CLAUDE_VOICE_DONE, "Sent");
    assert(!voice_on_update(&f, &u) && f.state == VOICE_CONFIRM);      /* done without our Send: ignored */
}

static void stale_updates_are_ignored(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);
    assert(voice_cancel(&f, out) == 5);
    const uint8_t want_cancel[5] = { 9, 0, 0, 0, 0x32 };
    assert(memcmp(out, want_cancel, 5) == 0 && f.state == VOICE_IDLE);
    claude_voice_t u = update(9, CLAUDE_VOICE_FINAL, "old");
    assert(!voice_on_update(&f, &u) && f.state == VOICE_IDLE);         /* the capture was cancelled */
    voice_begin(&f, 10, CLAUDE_VOICE_FOR_COMMAND, 0, 5, out);          /* Say again */
    assert(!voice_on_update(&f, &u) && f.state == VOICE_RECORDING && f.text[0] == '\0');
    assert(!voice_captured(&f, 9));
}

static void board_side_failure_shows_a_result(void)
{
    uint8_t out[CLAUDE_INPUT_MAX];
    voice_reset(&f);
    voice_begin(&f, 9, CLAUDE_VOICE_FOR_DENY, 0, 7, out);
    voice_captured(&f, 9);
    voice_fail(&f, "No answer from the Mac.");
    assert(f.state == VOICE_RESULT && !f.ok && strcmp(f.note, "No answer from the Mac.") == 0);
    assert(f.purpose == CLAUDE_VOICE_FOR_DENY && f.target == 7);       /* the caller still knows what it was for */
    voice_reset(&f);
    voice_fail(&f, "Mac not connected.");                              /* a start that never went out */
    assert(f.state == VOICE_RESULT && !f.ok);
}

int main(void)
{
    vad_ends_after_silence_following_speech();
    vad_pause_inside_a_sentence_keeps_going();
    vad_ends_when_nothing_is_said();
    vad_click_is_not_speech();
    vad_caps_a_long_capture();
    begin_encodes_the_start();
    command_round_trip();
    final_may_arrive_before_the_capture_callback();
    empty_final_cannot_be_sent();
    errors_end_the_capture();
    done_needs_a_send();
    stale_updates_are_ignored();
    board_side_failure_shows_a_result();
    puts("voice: all tests passed");
    return 0;
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd firmware/test && cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c 2>&1 | head -5; cc -Wall -Wextra -Werror -I../main -o /tmp/test_voice test_voice.c ../main/voice.c ../main/claude_proto.c 2>&1 | head -3`
Expected: compile errors (`'CLAUDE_VOICE' undeclared`, `voice.h: No such file or directory`).

- [ ] **Step 3: Protocol**

In `firmware/main/claude_proto.h`:

In the header comment, add after the `7 question page …` line:

```c
 *   8 voice           id = voice id    "<p|f|x|k>\ntext"   partial / final (what Send types) / error / done
```

and after the `[0 u32][0x21][handle u32 LE]         focus this session` line:

```c
 *   [voice u32][0x30][purpose u8][target u32 LE]   voice capture starts (purpose low nibble CLAUDE_VOICE_FOR_*,
 *                                        high nibble the question index for Other)
 *   [voice u32][0x31] / [0x32] / [0x33]  audio complete / cancel / send the final transcript
 *   Question answers: bit 7 of a mask = the spoken Other answer of that question.
 * Voice audio goes on its own characteristic (ble_link.c), never through these messages.
```

Add `CLAUDE_VOICE = 8,` after `CLAUDE_QUESTION = 7,` in `claude_kind_t`. Add after `#define CLAUDE_SESSION_UNSEEN  0x02`:

```c
#define CLAUDE_SESSION_VOICE   0x04   /* the session runs in a tmux pane the Mac can type into (Speak usable) */
```

and change the `flags` comment of `claude_session_t` to `/* CLAUDE_SESSION_* (0..7) */`.

Append at the end of the header:

```c
/* Voice (kind 8) */
#define CLAUDE_VOICE_TEXT_MAX 300   /* final transcript: Mac VoiceText.maxBytes */
#define CLAUDE_VOICE_PARTIAL  'p'
#define CLAUDE_VOICE_FINAL    'f'
#define CLAUDE_VOICE_ERROR    'x'
#define CLAUDE_VOICE_DONE     'k'

typedef struct {
    uint32_t id;                      /* voice id, never 0 */
    char what;                        /* CLAUDE_VOICE_* */
    char text[CLAUDE_TEXT_MAX + 1];
} claude_voice_t;

bool claude_parse_voice(const claude_msg_t *m, claude_voice_t *out);

#define CLAUDE_INPUT_VOICE_START  0x30
#define CLAUDE_INPUT_VOICE_STOP   0x31
#define CLAUDE_INPUT_VOICE_CANCEL 0x32
#define CLAUDE_INPUT_VOICE_SEND   0x33
#define CLAUDE_VOICE_FOR_COMMAND  0   /* typed into the session's tmux pane; target = session handle */
#define CLAUDE_VOICE_FOR_OTHER    1   /* spoken Other answer; target = question request id, question = page */
#define CLAUDE_VOICE_FOR_DENY     2   /* deny with the spoken reason; target = permission request id */

/* 10 bytes, or 0 when refused (voice or target 0, unknown purpose, a question index for anything but Other) */
size_t claude_encode_voice_start(uint32_t voice, uint8_t purpose, uint8_t question, uint32_t target,
                                 uint8_t out[CLAUDE_INPUT_MAX]);
/* code CLAUDE_INPUT_VOICE_STOP / CANCEL / SEND: 5 bytes, or 0 when refused */
size_t claude_encode_voice(uint32_t voice, uint8_t code, uint8_t out[CLAUDE_INPUT_MAX]);
```

In `firmware/main/claude_proto.c`:

In `claude_parse_session`, replace `flags < 0 || flags > (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_UNSEEN)) {` with `flags < 0 || flags > (CLAUDE_SESSION_FOCUSED | CLAUDE_SESSION_UNSEEN | CLAUDE_SESSION_VOICE)) {`.

Append:

```c
bool claude_parse_voice(const claude_msg_t *m, claude_voice_t *out)
{
    if (m->kind != CLAUDE_VOICE || m->id == 0 || !text_terminated(m)) {
        return false;
    }
    char w = m->text[0];
    if ((w != CLAUDE_VOICE_PARTIAL && w != CLAUDE_VOICE_FINAL && w != CLAUDE_VOICE_ERROR && w != CLAUDE_VOICE_DONE) ||
        m->text[1] != '\n') {
        return false;
    }
    out->id = m->id;
    out->what = w;
    size_t n = strlen(m->text + 2);   /* part of m->text: at most CLAUDE_TEXT_MAX - 2 */
    memcpy(out->text, m->text + 2, n + 1);
    return true;
}

size_t claude_encode_voice_start(uint32_t voice, uint8_t purpose, uint8_t question, uint32_t target,
                                 uint8_t out[CLAUDE_INPUT_MAX])
{
    if (voice == 0 || target == 0 || purpose > CLAUDE_VOICE_FOR_DENY || question >= CLAUDE_Q_MAX ||
        (purpose != CLAUDE_VOICE_FOR_OTHER && question != 0)) {
        return 0;
    }
    put32(out, voice);
    out[4] = CLAUDE_INPUT_VOICE_START;
    out[5] = (uint8_t)(purpose | question << 4);
    put32(out + 6, target);
    return 10;
}

size_t claude_encode_voice(uint32_t voice, uint8_t code, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (voice == 0 || code < CLAUDE_INPUT_VOICE_STOP || code > CLAUDE_INPUT_VOICE_SEND) {
        return 0;
    }
    put32(out, voice);
    out[4] = code;
    return 5;
}
```

In `firmware/main/sessions.c`, `sessions_set_focus`, replace `s->rows[i].flags = CLAUDE_SESSION_FOCUSED;   /* focused: no longer unseen */` with:

```c
            /* focused: no longer unseen; the voice flag belongs to the session, keep it */
            s->rows[i].flags = (uint8_t)((s->rows[i].flags & CLAUDE_SESSION_VOICE) | CLAUDE_SESSION_FOCUSED);
```

- [ ] **Step 4: The capture model**

Create `firmware/main/voice.h`:

```c
/*
 * Voice capture on the board (Phase 3), pure C, host-tested in firmware/test/test_voice.c.
 * Endpointing (audio task, one call per 20 ms frame): an energy VAD with an adaptive noise floor ends a capture
 *   1.5 s after speech stops, after 5 s without any speech (the Mac then returns an empty transcript), or at 30 s.
 * Flow (voice_ui.c, display lock): recording -> finishing -> confirm -> sending -> result. Each step returns the
 *   board -> Mac input bytes to send (claude_proto.h); nothing leaves confirm except through voice_send().
 *   Mac updates (kind 8) apply only to the current voice id and only in the states that expect them.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "claude_proto.h"

#define VOICE_START_FRAMES   2       /* 40 ms above threshold = speech */
#define VOICE_SILENCE_FRAMES 75      /* 1.5 s of silence after speech ends the capture */
#define VOICE_NOTHING_FRAMES 250     /* 5 s without speech ends it */
#define VOICE_MAX_FRAMES     1500    /* 30 s cap */
#define VOICE_MARGIN_DB      10.0f   /* speech must be this far above the noise floor */
#define VOICE_MIN_DB         -58.0f  /* and above this absolute level */
#define VOICE_FLOOR_RISE_DB  0.01f   /* per frame: the floor follows slowly rising noise */

typedef enum { VOICE_VAD_GO = 0, VOICE_VAD_SILENCE, VOICE_VAD_NOTHING, VOICE_VAD_MAX } voice_vad_result_t;

typedef struct {
    float floor_db;
    int frames;
    int above;    /* consecutive voiced frames */
    int quiet;    /* consecutive unvoiced frames */
    bool heard;   /* speech seen in this capture */
} voice_vad_t;

void voice_vad_init(voice_vad_t *v);
voice_vad_result_t voice_vad_step(voice_vad_t *v, float db);

typedef enum {
    VOICE_IDLE = 0,
    VOICE_RECORDING,   /* mic streaming to the Mac, partials shown */
    VOICE_FINISHING,   /* stop sent, waiting for the final transcript */
    VOICE_CONFIRM,     /* final shown: Say again / Cancel / Send (Use) */
    VOICE_SENDING,     /* send sent, waiting for done / error */
    VOICE_RESULT,      /* done or error shown */
} voice_state_t;

typedef struct {
    voice_state_t state;
    uint8_t purpose;                  /* CLAUDE_VOICE_FOR_* */
    uint8_t question;                 /* page, for CLAUDE_VOICE_FOR_OTHER */
    uint32_t target;                  /* session handle or request id */
    uint32_t id;                      /* voice id, never 0 while active */
    bool ok;                          /* RESULT: done (true) or error (false) */
    bool empty;                       /* CONFIRM: nothing was heard */
    char text[CLAUDE_TEXT_MAX + 1];   /* live, then final transcript */
    char note[CLAUDE_TEXT_MAX + 1];   /* RESULT line */
} voice_flow_t;

void voice_reset(voice_flow_t *f);
bool voice_active(const voice_flow_t *f);   /* recording .. sending */
/* The start bytes and RECORDING, or 0 (busy, id or target 0, bad purpose / question) */
size_t voice_begin(voice_flow_t *f, uint32_t id, uint8_t purpose, uint8_t question, uint32_t target,
                   uint8_t out[CLAUDE_INPUT_MAX]);
/* The audio task sent the stop for `id`: RECORDING -> FINISHING. False if it no longer applies. */
bool voice_captured(voice_flow_t *f, uint32_t id);
/* Back to IDLE; the cancel bytes while active (recording .. sending), else 0 */
size_t voice_cancel(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);
/* CONFIRM with a non-empty transcript: the send bytes and SENDING; else 0 */
size_t voice_send(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX]);
/* Applies a kind-8 update; true when the screen must be redrawn */
bool voice_on_update(voice_flow_t *f, const claude_voice_t *u);
/* Board-side failure (link lost, no answer in time, start not sent): RESULT with `note` */
void voice_fail(voice_flow_t *f, const char *note);
```

Create `firmware/main/voice.c`:

```c
#include "voice.h"

#include <stdio.h>
#include <string.h>

void voice_vad_init(voice_vad_t *v)
{
    memset(v, 0, sizeof(*v));
    v->floor_db = -60.0f;
}

voice_vad_result_t voice_vad_step(voice_vad_t *v, float db)
{
    v->frames++;
    /* Noise floor: drops at once to quieter frames, rises slowly so speech does not lift it */
    if (db < v->floor_db) {
        v->floor_db = db;
    } else {
        v->floor_db += VOICE_FLOOR_RISE_DB;
    }
    bool voiced = db > v->floor_db + VOICE_MARGIN_DB && db > VOICE_MIN_DB;
    v->above = voiced ? v->above + 1 : 0;
    if (v->above >= VOICE_START_FRAMES) {
        v->heard = true;
    }
    v->quiet = voiced ? 0 : v->quiet + 1;
    if (v->frames >= VOICE_MAX_FRAMES) {
        return VOICE_VAD_MAX;
    }
    if (v->heard && v->quiet >= VOICE_SILENCE_FRAMES) {
        return VOICE_VAD_SILENCE;
    }
    if (!v->heard && v->frames >= VOICE_NOTHING_FRAMES) {
        return VOICE_VAD_NOTHING;
    }
    return VOICE_VAD_GO;
}

void voice_reset(voice_flow_t *f)
{
    memset(f, 0, sizeof(*f));
}

bool voice_active(const voice_flow_t *f)
{
    return f->state >= VOICE_RECORDING && f->state <= VOICE_SENDING;
}

size_t voice_begin(voice_flow_t *f, uint32_t id, uint8_t purpose, uint8_t question, uint32_t target,
                   uint8_t out[CLAUDE_INPUT_MAX])
{
    if (voice_active(f)) {
        return 0;
    }
    size_t n = claude_encode_voice_start(id, purpose, question, target, out);
    if (n == 0) {
        return 0;
    }
    voice_reset(f);
    f->state = VOICE_RECORDING;
    f->id = id;
    f->purpose = purpose;
    f->question = question;
    f->target = target;
    return n;
}

bool voice_captured(voice_flow_t *f, uint32_t id)
{
    if (f->state != VOICE_RECORDING || id != f->id) {
        return false;
    }
    f->state = VOICE_FINISHING;
    return true;
}

size_t voice_cancel(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX])
{
    size_t n = voice_active(f) ? claude_encode_voice(f->id, CLAUDE_INPUT_VOICE_CANCEL, out) : 0;
    voice_reset(f);
    return n;
}

size_t voice_send(voice_flow_t *f, uint8_t out[CLAUDE_INPUT_MAX])
{
    if (f->state != VOICE_CONFIRM || f->empty) {
        return 0;
    }
    size_t n = claude_encode_voice(f->id, CLAUDE_INPUT_VOICE_SEND, out);
    if (n > 0) {
        f->state = VOICE_SENDING;
    }
    return n;
}

static bool blank(const char *s)
{
    for (; *s; s++) {
        if (*s != ' ') {
            return false;
        }
    }
    return true;
}

bool voice_on_update(voice_flow_t *f, const claude_voice_t *u)
{
    if (!voice_active(f) || u->id != f->id) {
        return false;
    }
    bool listening = f->state == VOICE_RECORDING || f->state == VOICE_FINISHING;
    switch (u->what) {
    case CLAUDE_VOICE_PARTIAL:
        if (!listening) {
            return false;
        }
        snprintf(f->text, sizeof(f->text), "%s", u->text);
        return true;
    case CLAUDE_VOICE_FINAL:
        if (!listening) {
            return false;
        }
        snprintf(f->text, sizeof(f->text), "%s", u->text);
        f->empty = blank(f->text);
        f->state = VOICE_CONFIRM;
        return true;
    case CLAUDE_VOICE_ERROR:
        voice_fail(f, u->text);
        return true;
    case CLAUDE_VOICE_DONE:
        if (f->state != VOICE_SENDING) {
            return false;
        }
        snprintf(f->note, sizeof(f->note), "%s", u->text);
        f->ok = true;
        f->state = VOICE_RESULT;
        return true;
    default:
        return false;
    }
}

void voice_fail(voice_flow_t *f, const char *note)
{
    snprintf(f->note, sizeof(f->note), "%s", note);
    f->ok = false;
    f->state = VOICE_RESULT;
}
```

In `firmware/main/CMakeLists.txt`, add `"voice.c"` after `"question.c"`.

- [ ] **Step 5: The spoken Other answer**

In `firmware/main/question.h`, add after `#include "claude_proto.h"`:

```c
#define QUESTION_OTHER     7      /* question_tap option: the spoken Other answer */
#define QUESTION_OTHER_BIT 0x80   /* its mask bit (the Mac maps it to the text it stored for that page) */
```

add to `question_set_t` after `uint8_t mask[CLAUDE_Q_MAX];`:

```c
    char other[CLAUDE_Q_MAX][CLAUDE_VOICE_TEXT_MAX + 1];   /* spoken Other answer per page, "" = none */
```

and after the `question_tap` declaration:

```c
/* Stores the spoken Other answer of `page` (after Use on the voice confirm screen) and selects it: single-select
 * instead of the option, multi-select alongside. "" removes it and its selection. question_tap(QUESTION_OTHER)
 * selects / toggles it like an option, only while a text is stored. */
void question_set_other(question_set_t *s, uint8_t page, const char *text);
```

In `firmware/main/question.c`, in `question_add`, after `s->mask[page->index] = 0;   /* … */` add:

```c
    s->other[page->index][0] = '\0';
```

Replace `question_tap` with:

```c
void question_tap(question_set_t *s, uint8_t option)
{
    if (!question_complete(s) || s->page >= s->count) {
        return;
    }
    const claude_question_t *q = &s->q[s->page];
    uint8_t bit;
    if (option == QUESTION_OTHER) {
        if (s->other[s->page][0] == '\0') {
            return;   /* nothing spoken yet: the row starts a voice capture instead (question_ui.c) */
        }
        bit = QUESTION_OTHER_BIT;
    } else if (option < q->nopt) {
        bit = (uint8_t)(1u << option);
    } else {
        return;
    }
    if (q->multi) {
        s->mask[s->page] ^= bit;
    } else {
        s->mask[s->page] = bit;
    }
}

void question_set_other(question_set_t *s, uint8_t page, const char *text)
{
    if (!question_complete(s) || page >= s->count) {
        return;
    }
    size_t n = claude_utf8_cut(text, strnlen(text, CLAUDE_VOICE_TEXT_MAX));
    memcpy(s->other[page], text, n);
    s->other[page][n] = '\0';
    if (n == 0) {
        s->mask[page] &= (uint8_t)~QUESTION_OTHER_BIT;
    } else if (s->q[page].multi) {
        s->mask[page] |= QUESTION_OTHER_BIT;
    } else {
        s->mask[page] = QUESTION_OTHER_BIT;
    }
}
```

- [ ] **Step 6: Run the tests**

Run:

```bash
cd firmware/test
cc -Wall -Wextra -Werror -I../main -o /tmp/test_claude_proto test_claude_proto.c ../main/claude_proto.c && /tmp/test_claude_proto
cc -Wall -Wextra -Werror -I../main -o /tmp/test_voice test_voice.c ../main/voice.c ../main/claude_proto.c && /tmp/test_voice
cc -Wall -Wextra -Werror -I../main -o /tmp/test_sessions test_sessions.c ../main/sessions.c ../main/claude_proto.c && /tmp/test_sessions
cc -Wall -Wextra -Werror -I../main -o /tmp/test_question test_question.c ../main/question.c ../main/claude_proto.c && /tmp/test_question
cc -Wall -Wextra -Werror -fsanitize=address,undefined -I../main -o /tmp/test_voice_asan test_voice.c ../main/voice.c ../main/claude_proto.c && /tmp/test_voice_asan
cd .. && . ~/esp/esp-idf/export.sh >/dev/null 2>&1 && idf.py build 2>&1 | grep -E "warning:|error:|Project build complete" | head
```

Expected: `claude_proto: all tests passed`, `voice: all tests passed`, `sessions: all tests passed`, `question: all tests passed` (twice for voice, the second under ASan/UBSan with no report); the firmware builds with no warnings from `firmware/main` (`voice.c` is compiled but not called yet; `question_set_t` grows by 1.2 KB of static RAM in `claude_ui.c`).

- [ ] **Step 7: Commit**

```bash
git add firmware/main/claude_proto.h firmware/main/claude_proto.c firmware/main/sessions.c firmware/main/question.h firmware/main/question.c firmware/main/voice.h firmware/main/voice.c firmware/main/CMakeLists.txt firmware/test/test_claude_proto.c firmware/test/test_sessions.c firmware/test/test_question.c firmware/test/test_voice.c
git commit -F - <<'EOF'
firmware: voice protocol (kind 8, voice inputs, session voice flag), capture model and spoken Other answers (host-tested)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 8: Firmware — voice capture to the Mac and the Speak flow on the Claude screen

**Files:**
- Rewrite: `firmware/main/audio_in.c`
- Create: `firmware/main/voice_ui.c`, `firmware/test/claude_ble_voice.py`
- Modify: `firmware/main/ble_link.c` (voice characteristic), `firmware/main/claude_ui.c` (Speak, `claude_ui_tap_armed`, voice hooks), `firmware/main/question_ui.c` (`question_ui_set_other`), `firmware/main/main.c` (kind 8, voice link), `firmware/main/ui.c` (panel stays on), `firmware/main/app.h`, `firmware/main/CMakeLists.txt`

**Interfaces:**
- Consumes: `voice.h` (`voice_vad_*`, `voice_flow_t` and its functions), `claude_parse_voice`, `claude_encode_voice`, `CLAUDE_VOICE_*`, `CLAUDE_SESSION_VOICE`, `question_set_other` (Task 7); `claude_ui_note_press`, `claude_ui_rearm`, `claude_ui_refresh_session_locked`, `picker_ui_focused_locked` (Phase 2).
- Produces (used by Task 9):
  - `bool ble_link_voice_ready(void);`, `uint16_t ble_link_voice_payload_max(void);`, `bool ble_link_send_voice(const uint8_t *data, uint16_t len);` (audio task only)
  - `bool audio_in_voice_start(uint32_t voice_id);`, `void audio_in_voice_stop(void);`, `void audio_in_voice_abort(void);`
  - `void voice_ui_init(lv_obj_t *scr);`, `bool voice_ui_start_locked(uint8_t purpose, uint8_t question, uint32_t target);` (true: the overlay is up, possibly showing an error), `void voice_ui_cancel_locked(void);`, `void voice_ui_request_gone_locked(uint32_t id);`, `bool voice_ui_active_locked(void);`, `void voice_ui_on_message(const claude_msg_t *m);`, `void voice_ui_set_link(bool on);`, `void voice_ui_capture_ended(uint32_t id);`, `void voice_ui_level(int percent);`
  - `bool claude_ui_tap_armed(void);` (lit panel + armed press; `claude_ui_tap_allowed()` = that + a pending request), `void claude_ui_voice_denied_locked(void);`, `void question_ui_set_other(uint8_t page, const char *text);`
  - `void app_on_claude_voice_link(bool on);`
  - `firmware/test/claude_ble_voice.py command|empty|error|other|deny|gone`

Threads: the audio task encodes and notifies voice packets and sends the stop input after the last packet (same link, so it never overtakes them), then calls `voice_ui_capture_ended()`; the NimBLE host task only parses kind 8 into a static buffer and updates labels; voice controls run in the LVGL task. No host test can drive LVGL or the codec: the logic lives in the host-tested `voice.c` (Task 7) and the wiring is checked on the device with a fake Mac (Step 9).

- [ ] **Step 1: Declarations**

In `firmware/main/app.h`:

After `void app_on_claude_message(const claude_msg_t *msg);` add:

```c
/* Mac voice characteristic subscribed / left (NimBLE host task) */
void app_on_claude_voice_link(bool on);
```

After `bool ble_link_send_claude_input(const uint8_t *data, size_t len);` add:

```c
/* Claude voice characteristic: the board mic to the Mac during a voice capture. Send from the audio task only. */
bool ble_link_voice_ready(void);
uint16_t ble_link_voice_payload_max(void);
bool ble_link_send_voice(const uint8_t *data, uint16_t len);
```

Replace `void audio_in_start(void);` (under `/* audio_in.c */`) with:

```c
void audio_in_start(void);
/* One voice capture at a time (voice_ui.c). start: false without the Mac voice link. stop: the audio task sends
 * its last packet, then the stop input, then calls voice_ui_capture_ended(). abort: stop streaming at once, no
 * stop input (the caller sent a cancel). */
bool audio_in_voice_start(uint32_t voice_id);
void audio_in_voice_stop(void);
void audio_in_voice_abort(void);
```

Replace the two lines

```c
bool claude_ui_tap_allowed(void);                   /* request pending, panel lit, press armed (dark: wakes) */
void claude_ui_rearm(void);                         /* new controls under the finger (page change) */
```

with

```c
bool claude_ui_tap_armed(void);                     /* panel lit, press armed (dark: wakes); voice controls */
bool claude_ui_tap_allowed(void);                   /* tap_armed and a request pending */
void claude_ui_rearm(void);                         /* new controls under the finger (page change) */
/* claude_ui.c: a spoken deny reason was applied (voice_ui.c): show "Denied", then restore */
void claude_ui_voice_denied_locked(void);
```

After `void question_ui_hide(void);  …` add:

```c
/* Use on the voice confirm screen: store the spoken Other answer of `page`, select it, redraw that page */
void question_ui_set_other(uint8_t page, const char *text);

/* voice_ui.c: voice capture overlay on the Claude screen (see the file header for the flow) */
void voice_ui_init(lv_obj_t *scr);                  /* after question_ui_init: on top of the question pages */
/* Display lock held (LVGL task): start a capture; purpose CLAUDE_VOICE_FOR_*, question = page (Other), target =
 * session handle or request id. True when the overlay is up (it may show an error). */
bool voice_ui_start_locked(uint8_t purpose, uint8_t question, uint32_t target);
void voice_ui_cancel_locked(void);                  /* drop any capture (sends cancel), hide the overlay */
void voice_ui_request_gone_locked(uint32_t id);     /* an Other / deny capture's request went away */
bool voice_ui_active_locked(void);                  /* the overlay is shown */
void voice_ui_on_message(const claude_msg_t *m);    /* kind 8, NimBLE host task; takes the lock */
void voice_ui_set_link(bool on);                    /* takes the lock */
void voice_ui_capture_ended(uint32_t id);           /* audio task, after its stop input; takes the lock */
void voice_ui_level(int percent);                   /* audio task: level ring, 0 = hidden; takes the lock */
```

In `firmware/main/CMakeLists.txt`, add `"voice_ui.c"` after `"question_ui.c"`.

- [ ] **Step 2: The voice characteristic**

In `firmware/main/ble_link.c`:

Replace the comment block above `s_claude_svc_uuid` and the three Claude UUID lines with:

```c
/* Claude companion service (the Mac). Requests: [flags u8][kind u8][id u32 LE][UTF-8], flags as the text chr.
 * Answers (notify): answers, board mode, focus and voice inputs, at most CLAUDE_INPUT_MAX bytes (claude_proto.h).
 * Voice (notify): the board mic as IMA ADPCM, same packets as the iPhone audio, only during a voice capture. */
static const ble_uuid128_t s_claude_svc_uuid = SVC_UUID(0x10);
static const ble_uuid128_t s_claude_req_uuid = SVC_UUID(0x11);
static const ble_uuid128_t s_claude_ans_uuid = SVC_UUID(0x12);
static const ble_uuid128_t s_claude_voice_uuid = SVC_UUID(0x13);
```

After `static uint16_t s_claude_ans_handle;` add:

```c
static uint16_t s_claude_voice_handle;
static volatile bool s_voice_on;   /* the Mac (s_mac_conn) subscribed to the voice characteristic */
```

In `s_services`, add a third characteristic to the Claude service after the answer characteristic:

```c
            {
                .uuid = &s_claude_voice_uuid.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC,   /* only while recording */
                .val_handle = &s_claude_voice_handle,
            },
```

In `gap_event`, `BLE_GAP_EVENT_DISCONNECT`, inside `if (event->disconnect.conn.conn_handle == s_mac_conn) {`, add `s_voice_on = false;` before `app_on_claude_link(false);`. In `BLE_GAP_EVENT_SUBSCRIBE`, inside the answer-characteristic branch, replace

```c
                if (!on) {
                    s_claude_rx.len = 0;
                }
```

with

```c
                if (!on) {
                    s_claude_rx.len = 0;
                    s_voice_on = false;   /* voice belongs to the Claude role */
                }
```

and insert this branch right before the `        }` line that closes the `if … else if …` chain of `BLE_GAP_EVENT_SUBSCRIBE` (the line just above its `break;`); that existing `}` then closes the new branch:

```c
        } else if (event->subscribe.attr_handle == s_claude_voice_handle) {
            /* Only the Mac that holds the Claude role streams voice */
            if (event->subscribe.conn_handle == s_mac_conn) {
                bool on = event->subscribe.cur_notify;
                if (on != s_voice_on) {
                    s_voice_on = on;
                    ESP_LOGI(TAG, "Mac voice %s", on ? "on" : "off");
                    app_on_claude_voice_link(on);
                }
            }
```

Append at the end of the file:

```c
bool ble_link_voice_ready(void)
{
    return s_mac_conn != BLE_HS_CONN_HANDLE_NONE && s_voice_on;
}

uint16_t ble_link_voice_payload_max(void)
{
    uint16_t conn = s_mac_conn;
    uint16_t mtu = conn == BLE_HS_CONN_HANDLE_NONE ? 0 : ble_att_mtu(conn);
    return mtu > 23 ? mtu - 3 : 20;
}

/* Audio task only: never from the NimBLE host task (its 6 KB stack has no room for the encoder path) */
bool ble_link_send_voice(const uint8_t *data, uint16_t len)
{
    for (int attempt = 0; attempt < 5; attempt++) {
        uint16_t conn = s_mac_conn;
        if (conn == BLE_HS_CONN_HANDLE_NONE || !s_voice_on) {
            return false;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
        if (om == NULL) {
            vTaskDelay(pdMS_TO_TICKS(2));
            continue;
        }
        int rc = ble_gatts_notify_custom(conn, s_claude_voice_handle, om);
        if (rc == 0) {
            return true;
        }
        if (rc != BLE_HS_ENOMEM) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    return false;
}
```

- [ ] **Step 3: The audio task**

Replace the whole of `firmware/main/audio_in.c` with:

```c
/*
 * Captures both ES7210 mics at 16 kHz, mixes to mono, IMA ADPCM encodes and streams over BLE:
 *   translator: to the iPhone (audio characteristic) while the board mic is on, gated by an energy VAD
 *   voice     : to the Mac (Claude voice characteristic) for one capture at a time (voice_ui.c): every frame from
 *               the start until voice.c's endpointing, Stop, an abort, or the Mac voice link going away
 * A voice capture pauses the translator stream (nothing goes to the iPhone meanwhile); the translator VAD starts
 * fresh afterwards, so no half phrase is sent. The codec is open only while one of them needs it.
 * Every packet carries its own ADPCM state, so a lost packet never corrupts the following ones.
 * Encoding and sending happen only in this task, never in the NimBLE host task (its stack is 6 KB).
 *
 * Translator power: silence costs no radio time on the board and no recognition work on the iPhone.
 * A 300 ms pre-roll keeps the first syllable; an 800 ms hangover keeps pauses inside a sentence.
 */
#include <math.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "adpcm.h"
#include "app.h"
#include "voice.h"

static const char *TAG = "audio";

#define SAMPLE_RATE   16000
#define FRAME_SAMPLES 320          /* 20 ms */
#define HEADER_BYTES  5
#define MIC_GAIN_DB   36.0f
#define WARMUP_FRAMES 10           /* drop the first 200 ms: codec start-up pop */

#define VAD_PREROLL_FRAMES  15     /* 300 ms sent before the detected start */
#define VAD_HANGOVER_FRAMES 40     /* keep streaming 800 ms after the last speech frame */
#define VAD_START_FRAMES    2      /* 40 ms above threshold to open */
#define VAD_MARGIN_DB       10.0f  /* speech must be this far above the noise floor */
#define VAD_MIN_DB          -58.0f /* and above this absolute level */
#define FLOOR_RISE_DB       0.01f  /* per frame (0.5 dB/s): floor follows slowly rising noise */

/* Level ring: -55 dBFS (faint, far) .. -25 dBFS (close, clear) → 1..100 */
#define RING_MIN_DB   -55.0f
#define RING_MAX_DB   -25.0f
#define RING_EVERY    6          /* update every 120 ms */

typedef enum { SINK_PHONE = 0, SINK_MAC } sink_t;

typedef struct {
    adpcm_state_t st;
    uint16_t seq;
    uint32_t sent, dropped;
} stream_t;

/* Translator VAD (the iPhone stream) */
typedef struct {
    float floor_db;
    int above;
    int hangover;
    bool speaking;
} translator_t;

static int16_t s_preroll[VAD_PREROLL_FRAMES][FRAME_SAMPLES];
static int s_preroll_head;
static int s_preroll_count;

/* Voice capture requests from voice_ui.c (LVGL or NimBLE host task); everything else belongs to this task */
#define VOICE_CMD_NONE  0
#define VOICE_CMD_STOP  1
#define VOICE_CMD_ABORT 2
static portMUX_TYPE s_voice_mux = portMUX_INITIALIZER_UNLOCKED;
static uint32_t s_voice_id;   /* requested capture, 0 = none */
static uint8_t s_voice_cmd;

static void put_header(uint8_t *pkt, uint16_t seq, const adpcm_state_t *st)
{
    pkt[0] = seq & 0xff;
    pkt[1] = seq >> 8;
    pkt[2] = (uint16_t)st->predictor & 0xff;
    pkt[3] = (uint16_t)st->predictor >> 8;
    pkt[4] = st->index;
}

static void send_frame(stream_t *s, const int16_t *mono, sink_t sink)
{
    static uint8_t pkt[HEADER_BYTES + FRAME_SAMPLES / 2];

    /* Split by negotiated MTU (iPhones usually give >= 185, enough for a full 20 ms frame) */
    uint16_t payload = sink == SINK_MAC ? ble_link_voice_payload_max() : ble_link_payload_max();
    int chunk = (payload - HEADER_BYTES) * 2;
    if (chunk > FRAME_SAMPLES) {
        chunk = FRAME_SAMPLES;
    }
    chunk &= ~1;
    for (int off = 0; off < FRAME_SAMPLES; off += chunk) {
        int n = FRAME_SAMPLES - off < chunk ? FRAME_SAMPLES - off : chunk;
        put_header(pkt, s->seq++, &s->st);
        adpcm_encode(&s->st, mono + off, n, pkt + HEADER_BYTES);
        bool ok = sink == SINK_MAC ? ble_link_send_voice(pkt, HEADER_BYTES + n / 2)
                                   : ble_link_send_audio(pkt, HEADER_BYTES + n / 2);
        if (ok) {
            s->sent++;
        } else {
            s->dropped++;
        }
    }
}

static int ring_percent(float db)
{
    float pct = (db - RING_MIN_DB) * 100.0f / (RING_MAX_DB - RING_MIN_DB);
    return pct < 1 ? 1 : pct > 100 ? 100 : (int)pct;
}

/* A fresh phrase: nothing held back, nothing half sent */
static void translator_reset(translator_t *t)
{
    t->above = 0;
    t->hangover = 0;
    t->speaking = false;
    s_preroll_count = s_preroll_head = 0;
}

static void translator_step(translator_t *t, stream_t *phone, const int16_t *mono, float db, uint32_t frames)
{
    /* Noise floor: drops immediately to quieter frames, rises slowly so speech doesn't lift it */
    if (db < t->floor_db) {
        t->floor_db = db;
    } else {
        t->floor_db += FLOOR_RISE_DB;
    }
    bool voiced = db > t->floor_db + VAD_MARGIN_DB && db > VAD_MIN_DB;
    t->above = voiced ? t->above + 1 : 0;

    if (!t->speaking && t->above >= VAD_START_FRAMES) {
        t->speaking = true;
        app_on_speech_activity();
        /* Flush the pre-roll oldest first, then continue live */
        int start = (s_preroll_head - s_preroll_count + VAD_PREROLL_FRAMES) % VAD_PREROLL_FRAMES;
        for (int i = 0; i < s_preroll_count; i++) {
            send_frame(phone, s_preroll[(start + i) % VAD_PREROLL_FRAMES], SINK_PHONE);
        }
        s_preroll_count = 0;
    }

    if (t->speaking) {
        send_frame(phone, mono, SINK_PHONE);
        if (voiced) {
            t->hangover = VAD_HANGOVER_FRAMES;
        } else if (--t->hangover <= 0) {
            t->speaking = false;
            ui_set_level(0);
        }
        if (t->speaking && frames % RING_EVERY == 0) {
            ui_set_level(ring_percent(db));
        }
    } else {
        memcpy(s_preroll[s_preroll_head], mono, sizeof(int16_t) * FRAME_SAMPLES);
        s_preroll_head = (s_preroll_head + 1) % VAD_PREROLL_FRAMES;
        if (s_preroll_count < VAD_PREROLL_FRAMES) {
            s_preroll_count++;
        }
    }
}

bool audio_in_voice_start(uint32_t voice_id)
{
    if (voice_id == 0 || !ble_link_voice_ready()) {
        return false;
    }
    taskENTER_CRITICAL(&s_voice_mux);
    s_voice_id = voice_id;
    s_voice_cmd = VOICE_CMD_NONE;
    taskEXIT_CRITICAL(&s_voice_mux);
    return true;
}

static void voice_command(uint8_t cmd)
{
    taskENTER_CRITICAL(&s_voice_mux);
    if (s_voice_id != 0) {
        s_voice_cmd = cmd;
    }
    taskEXIT_CRITICAL(&s_voice_mux);
}

void audio_in_voice_stop(void)
{
    voice_command(VOICE_CMD_STOP);
}

void audio_in_voice_abort(void)
{
    voice_command(VOICE_CMD_ABORT);
}

/* Ends capture `id` in this task. stop_input: tell the Mac the audio is complete (after the last packet, on the
 * same link, so it never overtakes it) and let the UI wait for the final transcript. */
static void end_voice(uint32_t id, bool stop_input, const char *why, const stream_t *mac)
{
    taskENTER_CRITICAL(&s_voice_mux);
    if (s_voice_id == id) {   /* a newer capture may already be requested: leave it */
        s_voice_id = 0;
        s_voice_cmd = VOICE_CMD_NONE;
    }
    taskEXIT_CRITICAL(&s_voice_mux);
    voice_ui_level(0);
    ESP_LOGI(TAG, "voice %lu ended (%s): sent %lu, dropped %lu", (unsigned long)id, why, (unsigned long)mac->sent,
             (unsigned long)mac->dropped);
    if (stop_input) {
        uint8_t buf[CLAUDE_INPUT_MAX];
        size_t n = claude_encode_voice(id, CLAUDE_INPUT_VOICE_STOP, buf);
        if (!ble_link_send_claude_input(buf, n)) {
            ESP_LOGW(TAG, "voice %lu: stop not sent", (unsigned long)id);
        }
        voice_ui_capture_ended(id);
    }
}

static void audio_task(void *arg)
{
    esp_codec_dev_handle_t mic = bsp_audio_codec_microphone_init();
    if (mic == NULL) {
        ESP_LOGE(TAG, "microphone init failed");
        vTaskDelete(NULL);
        return;
    }

    static int16_t raw[FRAME_SAMPLES * 2];
    static int16_t mono[FRAME_SAMPLES];

    bool open = false;
    stream_t phone = { 0 };
    stream_t mac = { 0 };
    translator_t tr = { .floor_db = -60.0f };
    voice_vad_t vad;
    voice_vad_init(&vad);
    uint32_t voice = 0;   /* capture this task is streaming, 0 = none */
    uint32_t frames = 0, warmup = 0;
    float peak_db = -100.0f;

    while (true) {
        uint32_t want_voice;
        uint8_t cmd;
        taskENTER_CRITICAL(&s_voice_mux);
        want_voice = s_voice_id;
        cmd = s_voice_cmd;
        taskEXIT_CRITICAL(&s_voice_mux);

        if (voice != 0 && want_voice != voice) {
            /* Replaced by a newer capture (Say again): the UI already sent the cancel */
            ESP_LOGI(TAG, "voice %lu replaced", (unsigned long)voice);
            voice = 0;
            voice_ui_level(0);
        }
        if (want_voice != 0 && cmd == VOICE_CMD_ABORT) {
            end_voice(want_voice, false, "aborted", &mac);
            voice = 0;
            continue;
        }
        if (voice == 0 && want_voice != 0) {
            voice = want_voice;
            memset(&mac, 0, sizeof(mac));
            voice_vad_init(&vad);
            translator_reset(&tr);   /* the iPhone stream pauses: no half phrase before or after */
            ui_set_level(0);
            ESP_LOGI(TAG, "voice %lu started", (unsigned long)voice);
        }

        bool translating = app_get_recording() != REC_NONE && ble_link_audio_ready();
        bool want = voice != 0 || translating;
        if (want != open) {
            if (want) {
                esp_codec_dev_sample_info_t fs = {
                    .sample_rate = SAMPLE_RATE,
                    .channel = 2,
                    .bits_per_sample = 16,
                };
                if (esp_codec_dev_open(mic, &fs) != ESP_CODEC_DEV_OK) {
                    ESP_LOGE(TAG, "open failed");
                    vTaskDelay(pdMS_TO_TICKS(500));
                    continue;
                }
                esp_codec_dev_set_in_gain(mic, MIC_GAIN_DB);
                memset(&phone, 0, sizeof(phone));
                frames = 0;
                warmup = WARMUP_FRAMES;
                translator_reset(&tr);
                ESP_LOGI(TAG, "recording started");
            } else {
                esp_codec_dev_close(mic);
                ui_set_level(0);
                voice_ui_level(0);
                ESP_LOGI(TAG, "recording stopped");
            }
            open = want;
        }
        if (!open) {
            vTaskDelay(pdMS_TO_TICKS(30));
            continue;
        }

        if (esp_codec_dev_read(mic, raw, sizeof(raw)) != ESP_CODEC_DEV_OK) {
            continue;
        }
        if (warmup > 0) {
            warmup--;
            continue;
        }

        double energy = 0;
        for (int i = 0; i < FRAME_SAMPLES; i++) {
            int32_t s = ((int32_t)raw[2 * i] + raw[2 * i + 1]) / 2;
            mono[i] = (int16_t)s;
            energy += (double)s * s;
        }
        float db = 10.0f * log10f((float)(energy / FRAME_SAMPLES) / (32768.0f * 32768.0f) + 1e-10f);
        if (db > peak_db) {
            peak_db = db;
        }

        if (voice != 0) {
            send_frame(&mac, mono, SINK_MAC);
            voice_vad_result_t r = voice_vad_step(&vad, db);
            if (frames % RING_EVERY == 0) {
                voice_ui_level(db > RING_MIN_DB ? ring_percent(db) : 0);
            }
            const char *why = cmd == VOICE_CMD_STOP          ? "stop"
                              : r == VOICE_VAD_SILENCE       ? "silence"
                              : r == VOICE_VAD_NOTHING       ? "nothing said"
                              : r == VOICE_VAD_MAX           ? "30 s"
                              : !ble_link_voice_ready()      ? "Mac voice link gone"
                                                             : NULL;
            if (why != NULL) {
                end_voice(voice, true, why, &mac);
                voice = 0;
            }
        } else if (translating) {
            translator_step(&tr, &phone, mono, db, frames);
        }

        if (++frames % 250 == 0) {   /* every 5 s */
            ESP_LOGI(TAG, "peak %.0f dB, floor %.0f dB, sent %lu, dropped %lu", peak_db, tr.floor_db,
                     (unsigned long)phone.sent, (unsigned long)phone.dropped);
            peak_db = -100.0f;
        }
    }
}

void audio_in_start(void)
{
    xTaskCreatePinnedToCore(audio_task, "audio_in", 6144, NULL, 6, NULL, 1);
}
```

- [ ] **Step 4: The voice overlay**

Create `firmware/main/voice_ui.c`:

```c
/*
 * Voice on the Claude screen (Phase 3): one overlay for every capture (Speak on the session view here; the
 * Other row and Deny + why start captures from question pages and permission requests).
 *   recording : level ring, "Listening…", the live transcript from the Mac, Stop where Speak was
 *   finishing : "One moment…"
 *   confirm   : "Send this?" ("Use this?" for an Other answer) + the final transcript, Say again / Send (Use),
 *               Cancel. Nothing heard: "Didn't catch that" + "Say again, or Cancel.", no Send.
 *   sending   : "Sending…"
 *   result    : "Sent" / "Not sent" + the Mac's line, then back to what is under the overlay
 * An Other answer that was stored, or a deny that was applied, closes the overlay at once (the question page
 * shows the answer, the Claude screen shows "Denied").
 * Flow and bytes: voice.c (host-tested). The mic streams only while recording (audio_in.c, its own task); the
 * Mac transcribes and types. Nothing is sent without an armed, lit tap on Send / Use (claude_ui_tap_armed), and
 * the confirm screen re-arms, so the tap that stopped the recording can never land on Send.
 * Locking: *_locked functions and LVGL callbacks run with the display lock held; the others take it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "esp_random.h"
#include "lvgl.h"

#include "app.h"
#include "voice.h"

LV_FONT_DECLARE(font_vi_22);
LV_FONT_DECLARE(font_vi_36);

static const char *TAG = "voice_ui";

#define COLOR_ACCENT 0x1e6fd9
#define COLOR_SEND   0x1f9d55
#define COLOR_GREY   0x3a3a3a
#define COLOR_STOP   0x8a1c1c
#define COLOR_ERROR  0xe0605a

#define RESULT_OK_MS  1500
#define RESULT_ERR_MS 3500
#define WAIT_MAC_MS   10000   /* finishing / sending without an answer from the Mac */

static voice_flow_t s_flow;       /* display lock */
static claude_voice_t s_update;   /* parse buffer: NimBLE host task only, kept off its 6 KB stack */
static uint32_t s_next_id;
static bool s_link;               /* the Mac subscribed to the voice characteristic */
static int s_level = -1;

static lv_obj_t *s_box;
static lv_obj_t *s_ring;
static lv_obj_t *s_title;
static lv_obj_t *s_text_box;
static lv_obj_t *s_text;
static lv_obj_t *s_stop;
static lv_obj_t *s_again;
static lv_obj_t *s_send;
static lv_obj_t *s_send_label;
static lv_obj_t *s_cancel;
static lv_timer_t *s_timer;       /* result close, or the wait for the Mac */

static void stop_timer(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
}

static void start_timer(uint32_t ms, lv_timer_cb_t cb)
{
    stop_timer();
    s_timer = lv_timer_create(cb, ms, NULL);
    lv_timer_set_repeat_count(s_timer, 1);
}

static void redraw(void)
{
    voice_state_t st = s_flow.state;
    bool other = s_flow.purpose == CLAUDE_VOICE_FOR_OTHER;
    const char *title = "";
    const char *body = s_flow.text;
    switch (st) {
    case VOICE_RECORDING:
        title = "Listening…";
        if (body[0] == '\0') {
            body = "Speak now.";
        }
        break;
    case VOICE_FINISHING:
        title = "One moment…";
        break;
    case VOICE_CONFIRM:
        if (s_flow.empty) {
            title = "Didn't catch that";
            body = "Say again, or Cancel.";
        } else {
            title = other ? "Use this?" : "Send this?";
        }
        break;
    case VOICE_SENDING:
        title = "Sending…";
        break;
    case VOICE_RESULT:
        title = s_flow.ok ? "Sent" : "Not sent";
        body = s_flow.note;
        break;
    default:
        body = "";
        break;
    }
    lv_label_set_text(s_title, title);
    lv_obj_set_style_text_color(s_title, lv_color_hex(st == VOICE_RESULT && !s_flow.ok ? COLOR_ERROR : 0xffffff), 0);
    lv_label_set_text(s_text, body);
    lv_obj_update_layout(s_text_box);
    if (st == VOICE_RECORDING || st == VOICE_FINISHING) {
        /* Live transcript: keep the newest words in view */
        lv_obj_scroll_to_y(s_text_box, lv_obj_get_scroll_y(s_text_box) + lv_obj_get_scroll_bottom(s_text_box),
                           LV_ANIM_OFF);
    } else {
        lv_obj_scroll_to_y(s_text_box, 0, LV_ANIM_OFF);
    }
    bool confirm = st == VOICE_CONFIRM;
    lv_obj_set_hidden(s_stop, st != VOICE_RECORDING);
    lv_obj_set_hidden(s_again, !confirm);
    lv_obj_set_hidden(s_cancel, !confirm);
    lv_obj_set_hidden(s_send, !(confirm && !s_flow.empty));
    lv_label_set_text(s_send_label, other ? "Use" : "Send");
    lv_obj_align(s_again, LV_ALIGN_BOTTOM_MID, s_flow.empty ? 0 : -82, -110);
    if (st != VOICE_RECORDING) {
        lv_obj_set_hidden(s_ring, true);
        s_level = 0;
    }
}

/* Hides the overlay; what is under it (session view, permission, question page) shows again */
static void close_overlay(void)
{
    stop_timer();
    lv_obj_set_hidden(s_ring, true);
    lv_obj_set_hidden(s_box, true);
    s_level = 0;
}

static void back_to_screen(uint8_t purpose)
{
    if (purpose == CLAUDE_VOICE_FOR_COMMAND) {
        claude_ui_refresh_session_locked();
    }
    claude_ui_rearm();   /* the controls under the finger are new */
}

/* LVGL timer, lock held: the result was read */
static void result_done_cb(lv_timer_t *t)
{
    s_timer = NULL;   /* one-shot: LVGL deletes it after this call */
    uint8_t purpose = s_flow.purpose;
    voice_reset(&s_flow);
    close_overlay();
    back_to_screen(purpose);
}

/* Lock held: the flow just reached RESULT */
static void on_result(void)
{
    audio_in_voice_abort();   /* an error may arrive while the mic still streams */
    if (s_flow.ok && s_flow.purpose == CLAUDE_VOICE_FOR_OTHER) {
        question_ui_set_other(s_flow.question, s_flow.text);   /* the page shows it, selected */
        voice_reset(&s_flow);
        close_overlay();
        claude_ui_rearm();
        return;
    }
    if (s_flow.ok && s_flow.purpose == CLAUDE_VOICE_FOR_DENY) {
        voice_reset(&s_flow);
        close_overlay();
        claude_ui_voice_denied_locked();
        return;
    }
    start_timer(s_flow.ok ? RESULT_OK_MS : RESULT_ERR_MS, result_done_cb);
}

/* LVGL timer, lock held: no final transcript or no send result from the Mac */
static void wait_cb(lv_timer_t *t)
{
    s_timer = NULL;
    if (s_flow.state != VOICE_FINISHING && s_flow.state != VOICE_SENDING) {
        return;
    }
    bool sending = s_flow.state == VOICE_SENDING;
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = claude_encode_voice(s_flow.id, CLAUDE_INPUT_VOICE_CANCEL, out);
    ble_link_send_claude_input(out, n);
    ESP_LOGW(TAG, "voice %lu: no answer from the Mac", (unsigned long)s_flow.id);
    voice_fail(&s_flow, sending ? "No answer from the Mac. Check the terminal." : "No answer from the Mac.");
    on_result();
    redraw();
}

bool voice_ui_start_locked(uint8_t purpose, uint8_t question, uint32_t target)
{
    if (s_box == NULL || !s_link || voice_active(&s_flow)) {
        return false;
    }
    if (s_flow.state == VOICE_RESULT) {   /* a result still on screen */
        stop_timer();
        voice_reset(&s_flow);
    }
    if (s_next_id == 0) {
        s_next_id = esp_random() | 1u;
    }
    uint32_t id = s_next_id++;
    if (s_next_id == 0) {
        s_next_id = 1;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_begin(&s_flow, id, purpose, question, target, out);
    if (n == 0) {
        return false;
    }
    lv_obj_set_hidden(s_box, false);
    /* The start goes out before the first packet: the audio task only streams after audio_in_voice_start */
    if (!ble_link_voice_ready() || !ble_link_send_claude_input(out, n) || !audio_in_voice_start(id)) {
        voice_fail(&s_flow, "Mac not connected.");
        on_result();
    } else {
        ESP_LOGI(TAG, "voice %lu: start (purpose %u, target %lu)", (unsigned long)id, (unsigned)purpose,
                 (unsigned long)target);
    }
    redraw();
    claude_ui_rearm();   /* Stop sits where Speak was: the tap that started must not stop */
    return true;
}

void voice_ui_cancel_locked(void)
{
    if (s_box == NULL || s_flow.state == VOICE_IDLE) {
        return;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_cancel(&s_flow, out);   /* back to IDLE */
    if (n > 0) {
        ble_link_send_claude_input(out, n);
    }
    audio_in_voice_abort();
    close_overlay();
}

void voice_ui_request_gone_locked(uint32_t id)
{
    if (s_flow.state != VOICE_IDLE && s_flow.purpose != CLAUDE_VOICE_FOR_COMMAND && s_flow.target == id) {
        voice_ui_cancel_locked();
    }
}

bool voice_ui_active_locked(void)
{
    return s_flow.state != VOICE_IDLE;
}

static void on_pressed(lv_event_t *e)
{
    claude_ui_note_press();
}

static void on_stop(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_RECORDING) {
        return;
    }
    audio_in_voice_stop();   /* the audio task sends the last packet, the stop, then voice_ui_capture_ended */
}

static void on_again(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_CONFIRM) {
        return;
    }
    uint8_t purpose = s_flow.purpose;
    uint8_t question = s_flow.question;
    uint32_t target = s_flow.target;
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_cancel(&s_flow, out);
    if (n > 0) {
        ble_link_send_claude_input(out, n);
    }
    if (!voice_ui_start_locked(purpose, question, target)) {
        close_overlay();
        back_to_screen(purpose);
    }
}

static void on_cancel(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_flow.state != VOICE_CONFIRM) {
        return;
    }
    uint8_t purpose = s_flow.purpose;
    voice_ui_cancel_locked();
    back_to_screen(purpose);
}

static void on_send(lv_event_t *e)
{
    if (!claude_ui_tap_armed()) {
        return;
    }
    uint8_t out[CLAUDE_INPUT_MAX];
    size_t n = voice_send(&s_flow, out);   /* only from CONFIRM with a transcript */
    if (n == 0) {
        return;
    }
    if (ble_link_send_claude_input(out, n)) {
        ESP_LOGI(TAG, "voice %lu: send", (unsigned long)s_flow.id);
        start_timer(WAIT_MAC_MS, wait_cb);
    } else {
        voice_fail(&s_flow, "Mac not connected.");
        on_result();
    }
    redraw();
}

/* Dark panel: the box is not clickable, so a tap reaches the screen and wakes it; the text box takes presses
 * (to scroll), so it wakes the panel itself */
static void on_text_tap(lv_event_t *e)
{
    ui_wake_from_tap();
}

static lv_obj_t *make_button(const char *text, uint32_t color, int width, lv_event_cb_t cb, lv_obj_t **label_out)
{
    lv_obj_t *b = lv_button_create(s_box);
    lv_obj_set_size(b, width, 52);
    lv_obj_set_style_radius(b, 26, 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_add_event_cb(b, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    if (label_out) {
        *label_out = l;
    }
    return b;
}

/* Layout on the 466 px circle (centre 233): title y 64 (320 wide), transcript y 122..292 (380 wide, scrolls),
 * Stop at the Speak spot (bottom -70), Say again / Send at bottom -110 (x -82 / +82), Cancel at bottom -48.
 * Every corner stays within r 222 of the centre. */
void voice_ui_init(lv_obj_t *scr)
{
    s_box = lv_obj_create(scr);   /* opaque, covers the Claude screen and question pages while shown */
    lv_obj_set_size(s_box, 466, 466);
    lv_obj_center(s_box);
    lv_obj_set_style_bg_color(s_box, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_box, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_box, 0, 0);
    lv_obj_set_style_radius(s_box, 0, 0);
    lv_obj_set_style_pad_all(s_box, 0, 0);
    lv_obj_set_scrollable(s_box, false);
    lv_obj_set_clickable(s_box, false);

    s_ring = lv_arc_create(s_box);
    lv_obj_set_size(s_ring, 462, 462);
    lv_obj_center(s_ring);
    lv_arc_set_bg_angles(s_ring, 0, 360);
    lv_arc_set_angles(s_ring, 0, 360);
    lv_obj_remove_style(s_ring, NULL, LV_PART_KNOB);
    lv_obj_set_clickable(s_ring, false);
    lv_obj_set_style_arc_opa(s_ring, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_ring, 6, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(s_ring, lv_color_hex(COLOR_ACCENT), LV_PART_INDICATOR);
    lv_obj_set_hidden(s_ring, true);

    s_title = lv_label_create(s_box);
    lv_obj_set_width(s_title, 320);
    lv_obj_set_style_text_font(s_title, &font_vi_36, 0);
    lv_obj_set_style_text_color(s_title, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_title, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_title, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(s_title, LV_ALIGN_TOP_MID, 0, 64);

    s_text_box = lv_obj_create(s_box);
    lv_obj_set_size(s_text_box, 380, 170);
    lv_obj_align(s_text_box, LV_ALIGN_TOP_MID, 0, 122);
    lv_obj_set_style_bg_opa(s_text_box, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_text_box, 0, 0);
    lv_obj_set_style_pad_all(s_text_box, 0, 0);
    lv_obj_set_style_radius(s_text_box, 0, 0);
    lv_obj_set_scroll_dir(s_text_box, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(s_text_box, LV_SCROLLBAR_MODE_AUTO);
    lv_obj_add_event_cb(s_text_box, on_text_tap, LV_EVENT_CLICKED, NULL);
    s_text = lv_label_create(s_text_box);
    lv_obj_set_width(s_text, 380);
    lv_obj_set_style_text_font(s_text, &font_vi_22, 0);
    lv_obj_set_style_text_color(s_text, lv_color_white(), 0);
    lv_obj_set_style_text_align(s_text, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    lv_obj_align(s_text, LV_ALIGN_TOP_MID, 0, 0);

    s_stop = make_button("Stop", COLOR_STOP, 150, on_stop, NULL);
    lv_obj_align(s_stop, LV_ALIGN_BOTTOM_MID, 0, -70);
    s_again = make_button("Say again", COLOR_GREY, 150, on_again, NULL);
    lv_obj_align(s_again, LV_ALIGN_BOTTOM_MID, -82, -110);
    s_send = make_button("Send", COLOR_SEND, 150, on_send, &s_send_label);
    lv_obj_align(s_send, LV_ALIGN_BOTTOM_MID, 82, -110);
    s_cancel = make_button("Cancel", COLOR_GREY, 130, on_cancel, NULL);
    lv_obj_align(s_cancel, LV_ALIGN_BOTTOM_MID, 0, -48);

    voice_reset(&s_flow);
    redraw();
    lv_obj_set_hidden(s_box, true);
}

void voice_ui_on_message(const claude_msg_t *m)
{
    if (!claude_parse_voice(m, &s_update)) {
        ESP_LOGW(TAG, "ignoring bad voice message for %lu", (unsigned long)m->id);
        return;
    }
    bsp_display_lock((uint32_t)-1);
    voice_state_t before = s_flow.state;
    if (s_box != NULL && voice_on_update(&s_flow, &s_update)) {
        if (s_flow.state == VOICE_CONFIRM && before != VOICE_CONFIRM) {
            stop_timer();
            claude_ui_rearm();   /* Send appears: only a new press may use it */
        }
        if (s_flow.state == VOICE_RESULT) {
            on_result();
        }
        if (s_flow.state != VOICE_IDLE) {
            redraw();
        }
    }
    bsp_display_unlock();
}

void voice_ui_set_link(bool on)
{
    bsp_display_lock((uint32_t)-1);
    s_link = on;
    if (!on && s_box != NULL && s_flow.state != VOICE_IDLE) {
        audio_in_voice_abort();
        voice_reset(&s_flow);
        close_overlay();
    }
    bsp_display_unlock();
}

void voice_ui_capture_ended(uint32_t id)
{
    bsp_display_lock((uint32_t)-1);
    if (s_box != NULL && voice_captured(&s_flow, id)) {
        start_timer(WAIT_MAC_MS, wait_cb);
        redraw();
    }
    bsp_display_unlock();
}

void voice_ui_level(int percent)
{
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }
    /* Redrawing the ring touches the whole screen: skip small changes */
    if (s_level >= 0 && (percent == 0) == (s_level == 0) && abs(percent - s_level) < 8) {
        return;
    }
    bsp_display_lock((uint32_t)-1);
    s_level = percent;
    if (s_box != NULL && s_flow.state == VOICE_RECORDING) {
        lv_obj_set_hidden(s_ring, percent == 0);
        if (percent != 0) {
            lv_obj_set_style_arc_width(s_ring, 3 + percent / 12, LV_PART_INDICATOR);
            lv_obj_set_style_arc_opa(s_ring, (lv_opa_t)(60 + percent * 195 / 100), LV_PART_INDICATOR);
        }
    }
    bsp_display_unlock();
}
```

- [ ] **Step 5: Speak on the Claude screen**

In `firmware/main/claude_ui.c`:

In the header comment, replace ` *   bottom : Deny / Allow, and Always allow when the Mac offers a rule, while a permission request is pending` with:

```c
 *   bottom : Deny / Allow, and Always allow when the Mac offers a rule, while a permission request is pending;
 *            on the session view, Speak (voice command, voice_ui.c) when the Mac voice link is up: disabled with
 *            "Open with cb for voice" when the focused session has no tmux pane the Mac can type into
```

After `static lv_obj_t *s_always;` add:

```c
static lv_obj_t *s_speak;
static lv_obj_t *s_speak_hint;
static uint32_t s_speak_handle;          /* focused session Speak would target; 0 = Speak not usable */
```

Add before `/* Info or result view: no request pending */`:

```c
/* Session view only: Speak for the focused session. Hidden without the Mac voice link or a live session;
 * disabled with a hint when the session has no tmux pane the Mac can type into. */
static void set_speak(const claude_session_t *f)
{
    bool show = f != NULL && s_link && ble_link_voice_ready() && f->state != CLAUDE_STATE_ENDED;
    bool usable = show && (f->flags & CLAUDE_SESSION_VOICE);
    lv_obj_set_hidden(s_speak, !show);
    lv_obj_set_state(s_speak, LV_STATE_DISABLED, !usable);
    lv_obj_set_hidden(s_speak_hint, !(show && !usable));
    s_speak_handle = usable ? f->handle : 0;
}
```

In `show_idle`, add `set_speak(NULL);` after `set_buttons(false);`. In `claude_ui_refresh_session_locked`, replace the last two lines

```c
    show_idle(title, f->line);
    lv_label_set_text(s_project, f->project);
```

with

```c
    show_idle(title, f->line);
    lv_label_set_text(s_project, f->project);
    set_speak(f);
```

In `cap_cb`, add `voice_ui_request_gone_locked(s_pending_id);` before `question_reset(&s_qset);`.

In `on_screen_unloaded`, add at the top: `voice_ui_cancel_locked();   /* leaving the Claude screen (BOOT, PWR, lock) drops a capture */`.

Replace `claude_ui_tap_allowed` with:

```c
bool claude_ui_tap_armed(void)
{
    /* A tap on a dark panel only wakes it; it must never act blind */
    if (!s_touch_on) {
        ui_wake_from_tap();
        return false;
    }
    /* Pressed before the controls were armed (something just appeared, page changed, panel just woke) */
    if (s_press_started_us < s_armed_at_us) {
        ESP_LOGI(TAG, "ignoring tap that began before the controls were armed");
        return false;
    }
    return true;
}

bool claude_ui_tap_allowed(void)
{
    return claude_ui_tap_armed() && s_pending_id != 0;
}
```

Add after `on_answer`:

```c
/* Runs in the LVGL task (lock already held) */
static void on_speak(lv_event_t *e)
{
    if (!claude_ui_tap_armed() || s_pending_id != 0 || s_speak_handle == 0) {
        return;
    }
    if (!voice_ui_start_locked(CLAUDE_VOICE_FOR_COMMAND, 0, s_speak_handle)) {
        ESP_LOGW(TAG, "voice capture not started");
    }
}
```

Replace `make_button` with a version that takes the callback:

```c
static lv_obj_t *make_button(const char *text, uint32_t color, int width, int x, int y_from_bottom, lv_event_cb_t cb,
                             uint8_t decision)
{
    lv_obj_t *b = lv_button_create(s_scr);
    lv_obj_set_size(b, width, 56);
    lv_obj_align(b, LV_ALIGN_BOTTOM_MID, x, y_from_bottom);
    lv_obj_set_style_radius(b, 28, 0);
    lv_obj_set_style_bg_color(b, lv_color_hex(color), 0);
    lv_obj_set_style_shadow_width(b, 0, 0);
    lv_obj_add_event_cb(b, on_press, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, (void *)(uintptr_t)decision);
    lv_obj_t *l = lv_label_create(b);
    lv_obj_set_style_text_font(l, &font_vi_22, 0);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_label_set_text(l, text);
    lv_obj_center(l);
    return b;
}
```

In `claude_ui_init`, replace the three `make_button` lines and the `question_ui_init` line with:

```c
    s_deny = make_button("Deny", 0x8a1c1c, 150, -80, -140, on_answer, CLAUDE_DECISION_DENY);
    s_allow = make_button("Allow", 0x1f9d55, 150, 80, -140, on_answer, CLAUDE_DECISION_ALLOW);
    s_always = make_button("Always allow", 0x1f5f8b, 220, 0, -74, on_answer, CLAUDE_DECISION_ALWAYS);
    /* Session view: Speak at y 340..396 (where voice_ui.c puts Stop), the hint above it */
    s_speak = make_button("Speak", 0x1e6fd9, 150, 0, -70, on_speak, 0);
    lv_obj_set_style_bg_color(s_speak, lv_color_hex(0x333333), LV_STATE_DISABLED);
    s_speak_hint = make_label(&font_vi_22, 0x9a9a9a, 340, 290);
    lv_label_set_text(s_speak_hint, "Open with cb for voice");
    lv_obj_set_hidden(s_speak, true);
    lv_obj_set_hidden(s_speak_hint, true);
    question_ui_init(s_scr, &s_qset);   /* after the buttons: the page box covers them while shown */
    voice_ui_init(s_scr);               /* last: the voice overlay covers question pages too */
```

In `claude_ui_on_message`, `case CLAUDE_PERMISSION:`, add `voice_ui_cancel_locked();   /* a request takes over: any capture ends */` right after `built_page = true;`. In `case CLAUDE_CANCEL:`, add `voice_ui_request_gone_locked(m->id);` as its first line. In `case CLAUDE_QUESTION:`, inside `if (question_add(&s_qset, m->id, &s_page)) {`, add `voice_ui_cancel_locked();` as its first line.

In `claude_ui_set_touch_enabled`, add `lv_obj_set_clickable(s_speak, on);` after `lv_obj_set_clickable(s_always, on);`.

Append:

```c
/* Display lock held (voice_ui.c): the Mac denied the pending request with the spoken reason */
void claude_ui_voice_denied_locked(void)
{
    ESP_LOGI(TAG, "Denied with a spoken reason for %lu", (unsigned long)s_pending_id);
    question_reset(&s_qset);
    show_idle("Denied", "Claude gets your reason.");
    schedule_restore();
}
```

In `firmware/main/question_ui.c`, append:

```c
void question_ui_set_other(uint8_t page, const char *text)
{
    question_set_other(s_set, page, text);
    if (s_box != NULL && !lv_obj_is_hidden(s_box) && page == s_set->page) {
        build_page();   /* from the voice result (NimBLE host task, lock held), never from a row's own event */
    }
}
```

- [ ] **Step 6: Dispatch, voice link and the panel**

In `firmware/main/main.c`:

In `app_on_claude_link`, add before `claude_ui_set_link(connected);`:

```c
    if (!connected) {
        voice_ui_set_link(false);   /* first: the Claude screen then drops a request a capture belongs to */
    }
```

Add after `app_on_claude_link`:

```c
/* NimBLE host task: the Mac subscribed to (or left) the voice characteristic */
void app_on_claude_voice_link(bool on)
{
    ESP_LOGI(TAG, "Claude voice %s", on ? "up" : "down");
    voice_ui_set_link(on);
    bsp_display_lock((uint32_t)-1);
    claude_ui_refresh_session_locked();   /* Speak appears or goes */
    bsp_display_unlock();
}
```

In `app_on_claude_message`, add before `default:`:

```c
    case CLAUDE_VOICE:
        voice_ui_on_message(msg);
        break;
```

In `firmware/main/ui.c`, `screen_timer_cb`, add after the `if (s_manual_off) { … }` block:

```c
    if (voice_ui_active_locked()) {
        set_screen(true);   /* a voice capture, its confirmation or its result is on screen */
        return;
    }
```

- [ ] **Step 7: The fake Mac for on-device checks**

Create `firmware/test/claude_ble_voice.py`:

```python
# firmware/test/claude_ble_voice.py — fake Mac daemon for the Phase 3 on-device voice checks.
# The board takes one Claude subscriber: stop the real daemon first and restart it afterwards:
#   launchctl bootout gui/$(id -u)/dev.cicca.claude-board
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.cicca.claude-board.plist
# usage: python3 claude_ble_voice.py command|empty|error|other|deny|gone   (needs bleak: python3 -m pip install --user bleak)
# Every capture's audio is saved to /tmp/board-voice-<voice id>.wav (listen with afplay).
import asyncio
import struct
import sys
import time
import wave

from bleak import BleakClient, BleakScanner

B = "-3b2f-4c1e-9d8a-5f6e7d8c9b0a"
TRANSLATOR_SVC = "a7c00001" + B
REQ, ANS, VOICE = "a7c00011" + B, "a7c00012" + B, "a7c00013" + B

INDEX = [-1, -1, -1, -1, 2, 4, 6, 8] * 2
STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
        88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598,
        658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
        16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]


def adpcm_decode(packet):
    pred = struct.unpack("<h", packet[2:4])[0]
    idx = min(88, packet[4])
    out = []
    for byte in packet[5:]:
        for code in (byte & 0x0F, byte >> 4):
            step = STEP[idx]
            delta = step >> 3
            if code & 4:
                delta += step
            if code & 2:
                delta += step >> 1
            if code & 1:
                delta += step >> 2
            pred = max(-32768, min(32767, pred - delta if code & 8 else pred + delta))
            idx = max(0, min(88, idx + INDEX[code]))
            out.append(pred)
    return out


def message(kind, mid, text=""):
    return bytes([kind]) + struct.pack("<I", mid) + text.encode()


def chunks(data, size):
    out = []
    for off in range(0, len(data), size - 1):
        part = data[off:off + size - 1]
        flags = (1 if off == 0 else 0) | (2 if off + size - 1 >= len(data) else 0)
        out.append(bytes([flags]) + part)
    return out


def describe(d):
    mid, code = struct.unpack("<IB", d[:5])
    if mid == 0 and code == 0x20:
        return "mode " + {0: "other", 1: "claude", 2: "picker"}.get(d[5], str(d[5]))
    if mid == 0 and code == 0x21:
        return "focus %d" % struct.unpack("<I", d[5:9])[0]
    if code == 0x30:
        kind = {0: "command", 1: "other q%d" % (d[5] >> 4), 2: "deny reason"}.get(d[5] & 0x0F, "?")
        return "voice %d start: %s, target %d" % (mid, kind, struct.unpack("<I", d[6:10])[0])
    if code in (0x31, 0x32, 0x33):
        return "voice %d %s" % (mid, {0x31: "stop", 0x32: "cancel", 0x33: "send"}[code])
    if code in (1, 2, 3):
        return "id %d %s" % (mid, {1: "allow", 2: "deny", 3: "always allow"}[code])
    if code == 0x10:
        return "id %d answers %s" % (mid, [hex(m) for m in d[6:6 + d[5]]])
    return "unknown " + d.hex()


async def main(what):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TRANSLATOR_SVC in [u.lower() for u in ad.service_uuids], timeout=15)
    assert dev, "board not found"
    async with BleakClient(dev) as c:
        inputs = asyncio.Queue()
        cap = {"seq": None, "lost": 0, "packets": 0, "samples": []}

        def on_input(_, data):
            data = bytes(data)
            print("board ->", describe(data))
            inputs.put_nowait(data)

        def on_voice(_, data):
            data = bytes(data)
            seq = struct.unpack("<H", data[:2])[0]
            if cap["seq"] is not None and seq != (cap["seq"] + 1) & 0xFFFF:
                cap["lost"] += (seq - cap["seq"] - 1) & 0xFFFF
            cap["seq"] = seq
            cap["packets"] += 1
            cap["samples"] += adpcm_decode(data)

        await c.start_notify(ANS, on_input)
        await c.start_notify(VOICE, on_voice)

        async def send(kind, mid, text=""):
            for ch in chunks(message(kind, mid, text), c.mtu_size - 3):
                await c.write_gatt_char(REQ, ch, response=True)

        async def wait_for(pred, secs):
            end = time.monotonic() + secs
            while time.monotonic() < end:
                try:
                    d = await asyncio.wait_for(inputs.get(), end - time.monotonic())
                except asyncio.TimeoutError:
                    break
                if pred(d):
                    return d
            raise SystemExit("timed out")

        def voice_input(vid, *codes):
            return lambda d: d[:4] == struct.pack("<I", vid) and d[4] in codes

        async def capture(final_text):
            """Waits for a voice start, streams fake partials until the stop, answers with final_text (None: the
            start is refused with an error). Returns the voice id."""
            d = await wait_for(lambda d: d[4] == 0x30, 180)
            vid = struct.unpack("<I", d[:4])[0]
            cap.update(seq=None, lost=0, packets=0, samples=[])
            if final_text is None:
                await send(8, vid, "x\nOpen with cb for voice")
                return vid
            while True:
                try:
                    d = await asyncio.wait_for(inputs.get(), 0.5)
                except asyncio.TimeoutError:
                    await send(8, vid, "p\n(fake Mac) %.1f s of audio" % (len(cap["samples"]) / 16000))
                    continue
                if voice_input(vid, 0x31)(d):
                    break
                if voice_input(vid, 0x32)(d):
                    print("cancelled while recording")
                    return vid
            total = cap["packets"] + cap["lost"]
            print("audio: %.2f s in %d packets, %d lost (%.1f%%)" % (len(cap["samples"]) / 16000, cap["packets"],
                                                                     cap["lost"], 100.0 * cap["lost"] / max(1, total)))
            path = "/tmp/board-voice-%d.wav" % vid
            with wave.open(path, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(struct.pack("<%dh" % len(cap["samples"]), *cap["samples"]))
            print("saved", path)
            await send(8, vid, "f\n" + final_text)
            return vid

        async def confirm(vid, done_text):
            """Send → answers done; returns "sent", or "cancel" (Cancel or Say again)."""
            d = await wait_for(voice_input(vid, 0x32, 0x33), 180)
            if d[4] == 0x33:
                await send(8, vid, "k\n" + done_text)
                return "sent"
            return "cancel"

        now = int(time.time())
        await send(3, 0, "%d %d" % (now, time.localtime().tm_gmtoff // 60))

        if what in ("command", "empty", "error"):
            print("Press PWR x2 on the board (Claude screen).")
            await wait_for(lambda d: d[:5] == b"\0\0\0\0\x20" and d[5] == 1, 120)
            await send(6, 0)
            await send(4, 1, "i %d %d 5\nesp32-translator\nReady for a command." % (now - 60, now))
            await send(4, 2, "i %d %d 0\nno-cb\nRuns without tmux." % (now - 30, now - 30))

        if what == "command":
            print("Expect Speak under 'Ready for a command.'. Tap Speak, say a sentence, then stop talking.")
            vid = await capture("chạy các bài kiểm tra")
            print("Expect 'Send this?' + 'chạy các bài kiểm tra'. Tap Say again once, speak again, then Send.")
            while await confirm(vid, "Sent to esp32-translator") != "sent":
                vid = await capture("chạy các bài kiểm tra")
            print("Expect 'Sent' / 'Sent to esp32-translator', then the session view with Speak.")
            await asyncio.sleep(3)

        if what == "empty":
            print("Tap Speak and say nothing for 5 s.")
            vid = await capture("")
            print("Expect 'Didn't catch that' / 'Say again, or Cancel.' and no Send. Tap Cancel.")
            await confirm(vid, "")
            await asyncio.sleep(2)

        if what == "error":
            print("Tap Speak.")
            await capture(None)
            print("Expect 'Not sent' / 'Open with cb for voice' for ~3.5 s, then the session view.")
            await asyncio.sleep(5)

        if what == "other":
            qid = 7171
            await send(7, qid, "0 1 0 2\nesp32-translator\nFruit\nWhich fruit should the demo use?\n"
                               "Apple\nCrisp\nBanana\nSoft")
            print("Expect the question with an 'Other (speak)' row. Tap it, say a fruit, then Use.")
            vid = await capture("Sầu riêng")
            while await confirm(vid, "Added as your answer") != "sent":
                vid = await capture("Sầu riêng")
            print("Expect the Other row to read 'Sầu riêng', selected. Tap Send.")
            d = await wait_for(lambda d: d[:4] == struct.pack("<I", qid) and d[4] == 0x10, 120)
            print("answers:", describe(d), "(expect ['0x80'])")

        if what == "deny":
            pid = 8181
            await send(0, pid, "esp32-translator\nBash\nnpm test -- --watch=false")
            print("Expect Deny / Allow and 'Deny + why'. Tap Deny + why, give a reason, then Send.")
            vid = await capture("dùng pnpm thay vì npm")
            while await confirm(vid, "Denied with your reason") != "sent":
                vid = await capture("dùng pnpm thay vì npm")
            print("Expect 'Denied' / 'Claude gets your reason.', then the previous screen.")
            await asyncio.sleep(3)

        if what == "gone":
            pid = 9191
            await send(0, pid, "esp32-translator\nBash\nrm -rf build")
            print("Tap Deny + why and keep talking: the request is answered elsewhere after 3 s.")
            d = await wait_for(lambda d: d[4] == 0x30, 180)
            vid = struct.unpack("<I", d[:4])[0]
            await asyncio.sleep(3)
            await send(2, pid)
            await wait_for(voice_input(vid, 0x32), 10)
            print("Expect the overlay gone and 'Answered in the terminal or timed out.', then the previous screen.")
            await asyncio.sleep(3)


asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "command"))
```

- [ ] **Step 8: Build**

Run:

```bash
cd firmware/test && cc -Wall -Wextra -Werror -I../main -o /tmp/test_voice test_voice.c ../main/voice.c ../main/claude_proto.c && /tmp/test_voice
python3 -m py_compile claude_ble_voice.py && echo script ok
cd .. && . ~/esp/esp-idf/export.sh >/dev/null 2>&1 && idf.py build 2>&1 | grep -E "warning:|error:|Project build complete" | head
```

Expected: `voice: all tests passed`, `script ok`, and the firmware builds with no warnings from `firmware/main`.

- [ ] **Step 9: On-device check (controller with the user; hardware needed)**

Flash (`idf.py -p /dev/cu.usbmodem1101 flash monitor`), stop the real daemon (commands at the top of the script), install `bleak` if `python3 -c "import bleak"` fails (`python3 -m pip install --user bleak`), then run `python3 firmware/test/claude_ble_voice.py <scenario>` from the repository root while the user follows the printed prompts:

| # | Scenario | Expect |
|---|---|---|
| 1 | `command` | Speak under the session line (session `esp32-translator`, voice flag set); tap → "Listening…" with the level ring following the voice and "(fake Mac) N s of audio" updating; stops by itself ~1.5 s after speaking; "Send this?" + the text; Say again restarts; Send → "Sent" → session view. Script prints `audio: … lost (≤ 2%)`; `afplay /tmp/board-voice-<id>.wav` plays the user's voice clearly |
| 2 | `command`, but tap Stop while still talking | Stops at once (log `voice … ended (stop)`) |
| 3 | `empty` | "Didn't catch that" after ~5 s, no Send; Cancel → session view |
| 4 | `error` | "Not sent" / "Open with cb for voice" in red, then the session view |
| 5 | PWR x3, tap the `no-cb` row, PWR x2 | Speak greyed out with "Open with cb for voice"; tapping it does nothing |
| 6 | During a recording press BOOT | Translator screen; log `voice … ended (aborted)`; the script prints `cancelled while recording` |
| 7 | With the iPhone translator streaming (Mic on), run `command` | While recording, the iPhone gets no audio (no new subtitles); afterwards translation resumes with the next phrase |
| 8 | Kill the script during "Listening…" | The overlay closes (Mac gone); the Claude screen shows "Mac not connected" |

Also read the logs: the existing `stack headroom nimble_host: N bytes` line (printed after a permission or question page) must still show ≥ 2 KB after a few voice captures (the host task only parses voice messages into a static buffer), and the `audio` logs show `voice … started` / `ended (silence)`. Restart the real daemon afterwards.

- [ ] **Step 10: Commit**

```bash
git add firmware/main firmware/test/claude_ble_voice.py
git commit -F - <<'EOF'
firmware: voice capture to the Mac (own characteristic, audio task), voice overlay and Speak on the Claude screen

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 9: Firmware — spoken "Other" answers on question pages and "Deny + why" on permission requests

**Files:**
- Modify: `firmware/main/question_ui.c` (Other row), `firmware/main/claude_ui.c` (Deny + why)

**Interfaces:**
- Consumes: `QUESTION_OTHER`, `QUESTION_OTHER_BIT`, `question_set_t.other`, `question_tap` (Task 7); `voice_ui_start_locked`, `claude_ui_tap_allowed`, `ble_link_voice_ready`, `question_ui_set_other`, `claude_ui_voice_denied_locked` (Task 8); `CLAUDE_VOICE_FOR_OTHER`, `CLAUDE_VOICE_FOR_DENY` (Task 7).
- Produces: the user-facing entry points; nothing new for code.

Behaviour (agreed): the Other row appears on every question page while the Mac voice link is up, after the options: "Other (speak)" until something was spoken, then the spoken text. Tapping it with nothing spoken starts a capture for that page; "Use" on the confirm screen stores the text on the Mac and selects the row (single-select: instead of the option; multi-select: alongside); the answers still go only with the page's Send. Tapping it once text exists selects / toggles it like an option; a long press records it again. "Deny + why" sits under Deny / Allow (beside Always allow when that is offered); Send on its confirm screen denies the request with the spoken reason. Both use the request controls' arming (`claude_ui_tap_allowed`).

- [ ] **Step 1: The Other row**

In `firmware/main/question_ui.c`:

In the header comment, replace ` * No "Other" row in Phase 2 (voice answers come with Phase 3).` with:

```c
 *   Other  : while the Mac voice link is up, a last row "Other (speak)": tap to say the answer (voice_ui.c),
 *            Use stores it on the Mac and selects the row (shown as the spoken text); tap again to (un)select,
 *            long-press to say it again. Its mask bit is QUESTION_OTHER_BIT.
```

After `static lv_obj_t *s_marks[CLAUDE_OPT_MAX];` add:

```c
static lv_obj_t *s_other_row;     /* NULL when the page has no Other row (no Mac voice link) */
static lv_obj_t *s_other_mark;
```

In `refresh_marks`, add after the `for` loop:

```c
    if (s_other_mark != NULL) {
        bool on = (mask & QUESTION_OTHER_BIT) != 0;
        lv_obj_set_style_bg_color(s_other_mark, lv_color_hex(on ? COLOR_ACCENT : 0x000000), 0);
        lv_obj_set_style_bg_color(s_other_row, lv_color_hex(on ? COLOR_ROW_ON : COLOR_ROW), 0);
    }
```

Add after `on_row_long`:

```c
/* Other row: say the answer, or (once said) select / toggle it like an option */
static void on_other_tap(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    if (s_set->other[s_set->page][0] == '\0') {
        voice_ui_start_locked(CLAUDE_VOICE_FOR_OTHER, s_set->page, s_set->id);
        return;
    }
    question_tap(s_set, QUESTION_OTHER);
    refresh_marks();
}

/* Other row long press: say it again (Use replaces the text) */
static void on_other_long(lv_event_t *e)
{
    if (!claude_ui_tap_allowed()) {
        return;
    }
    voice_ui_start_locked(CLAUDE_VOICE_FOR_OTHER, s_set->page, s_set->id);
}
```

Replace `make_row` with a version that also builds the Other row (`i == QUESTION_OTHER`):

```c
static lv_obj_t *make_row(int i, const claude_question_t *q)
{
    bool other = i == QUESTION_OTHER;
    const char *spoken = s_set->other[s_set->page];
    lv_obj_t *row = lv_obj_create(s_list);
    lv_obj_set_width(row, 330);
    lv_obj_set_height(row, LV_SIZE_CONTENT);
    lv_obj_set_style_min_height(row, 52, 0);
    lv_obj_set_style_radius(row, 16, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_hor(row, 14, 0);
    lv_obj_set_style_pad_ver(row, 10, 0);
    lv_obj_set_style_pad_column(row, 12, 0);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollable(row, false);   /* a drag scrolls the list */
    lv_obj_add_event_cb(row, on_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(row, other ? on_other_tap : on_row_tap, LV_EVENT_SHORT_CLICKED, (void *)(uintptr_t)i);
    lv_obj_add_event_cb(row, other ? on_other_long : on_row_long, LV_EVENT_LONG_PRESSED, (void *)(uintptr_t)i);

    lv_obj_t *mark = lv_obj_create(row);   /* radio (circle) or checkbox (rounded square) */
    lv_obj_set_size(mark, 22, 22);
    lv_obj_set_style_radius(mark, q->multi ? 4 : LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(mark, 2, 0);
    lv_obj_set_style_border_color(mark, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(mark, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(mark, 0, 0);
    lv_obj_set_clickable(mark, false);
    lv_obj_set_scrollable(mark, false);

    lv_obj_t *label = lv_label_create(row);
    lv_obj_set_width(label, 262);
    lv_obj_set_style_text_font(label, &font_vi_22, 0);
    lv_obj_set_style_text_color(label, lv_color_hex(other && spoken[0] == '\0' ? COLOR_MUTED : 0xffffff), 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text(label, !other ? CLAUDE_Q_STR(q, label[i]) : spoken[0] ? spoken : "Other (speak)");

    if (other) {
        s_other_mark = mark;
    } else {
        s_marks[i] = mark;
    }
    return row;
}
```

In `build_page`, replace

```c
    for (int i = 0; i < CLAUDE_OPT_MAX; i++) {
        s_rows[i] = NULL;
        s_marks[i] = NULL;
    }
    for (int i = 0; i < q->nopt; i++) {
        s_rows[i] = make_row(i, q);
    }
```

with

```c
    for (int i = 0; i < CLAUDE_OPT_MAX; i++) {
        s_rows[i] = NULL;
        s_marks[i] = NULL;
    }
    s_other_row = NULL;
    s_other_mark = NULL;
    for (int i = 0; i < q->nopt; i++) {
        s_rows[i] = make_row(i, q);
    }
    if (ble_link_voice_ready()) {   /* no Mac voice link: no Other row */
        s_other_row = make_row(QUESTION_OTHER, q);
    }
```

- [ ] **Step 2: Deny + why**

In `firmware/main/claude_ui.c`:

In the header comment, after the `bottom : Deny / Allow, …` lines, add:

```c
 *            Deny + why (when the Mac voice link is up): say the reason, Send denies with it (voice_ui.c)
```

After `static lv_obj_t *s_always;` add `static lv_obj_t *s_deny_why;`.

Replace `set_buttons` with:

```c
/* Deny / Allow at y 270..326; second row at y 336..392: Deny + why and Always allow side by side (160 wide at
 * x -85 / +85), or whichever of them is offered, centred */
static void set_buttons(bool visible)
{
    bool why = visible && ble_link_voice_ready();
    bool always = visible && s_always_offered;
    lv_obj_set_hidden(s_allow, !visible);
    lv_obj_set_hidden(s_deny, !visible);
    lv_obj_set_hidden(s_always, !always);
    lv_obj_set_hidden(s_deny_why, !why);
    lv_obj_set_width(s_always, why ? 160 : 220);
    lv_obj_align(s_always, LV_ALIGN_BOTTOM_MID, why ? 85 : 0, -74);
    lv_obj_set_width(s_deny_why, always ? 160 : 180);
    lv_obj_align(s_deny_why, LV_ALIGN_BOTTOM_MID, always ? -85 : 0, -74);
}
```

Add after `on_speak`:

```c
/* Runs in the LVGL task (lock already held): say why, Send denies with it */
static void on_deny_why(lv_event_t *e)
{
    if (!claude_ui_tap_allowed() || s_qset.id == s_pending_id) {   /* permission requests only */
        return;
    }
    if (!voice_ui_start_locked(CLAUDE_VOICE_FOR_DENY, 0, s_pending_id)) {
        ESP_LOGW(TAG, "voice capture not started");
    }
}
```

In `claude_ui_init`, add after the `s_always = make_button(…)` line:

```c
    s_deny_why = make_button("Deny + why", 0x5a2323, 180, 0, -74, on_deny_why, 0);
```

and in `claude_ui_set_touch_enabled`, add `lv_obj_set_clickable(s_deny_why, on);` after `lv_obj_set_clickable(s_speak, on);`.

- [ ] **Step 3: Build**

Run: `. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && cd firmware && idf.py build 2>&1 | grep -E "warning:|error:|Project build complete" | head`
Expected: builds with no warnings from `firmware/main`.

- [ ] **Step 4: On-device check (controller with the user; hardware needed)**

Flash, stop the real daemon, and run `python3 firmware/test/claude_ble_voice.py <scenario>`:

| # | Scenario | Expect |
|---|---|---|
| 1 | `other` | Question page with Apple, Banana and a muted "Other (speak)" row; tap it → overlay "Listening…"; "Use this?" + "Sầu riêng" with Say again / Use / Cancel; Use → the page shows "Sầu riêng" selected (radio); Send → the script prints `answers: id 7171 answers ['0x80']` |
| 2 | `other`; after Use, tap Apple, then tap the Other row | Apple replaces the spoken answer; tapping the row selects "Sầu riêng" again without recording; long-press the row → a new recording, Use replaces the text |
| 3 | `other`; on the confirm screen tap Cancel | Back on the page, Other row still "Other (speak)", nothing selected; Send stays disabled |
| 4 | `deny` | Deny / Allow and "Deny + why" (centred); tap it → "Send this?" + the reason; Send → "Denied" / "Claude gets your reason.", then the previous screen |
| 5 | `gone` | During "Listening…" the request disappears: the overlay closes, "Answered in the terminal or timed out." shows; the script sees the voice cancel |
| 6 | Mac voice link off (run `claude_ble_phase2.py permission`, which does not subscribe to voice) | No "Deny + why", no Other row (Phase 2 behaviour unchanged) |

Restart the real daemon afterwards.

- [ ] **Step 5: Commit**

```bash
git add firmware/main/question_ui.c firmware/main/claude_ui.c
git commit -F - <<'EOF'
firmware: spoken Other answers on question pages and Deny + why on permission requests

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```

---

### Task 10: README and end-to-end acceptance with a real `cb` session (controller + user)

This task is run by the controller together with the user (board in hand, real Claude Code sessions). The controller edits the README and installs; the user speaks, taps and reports what the board shows.

**Files:**
- Modify: `README.md` (Repository layout, BLE protocol table, Claude companion mode, Safety rules)

**Interfaces:**
- Consumes: everything above.
- Produces: user documentation; nothing for code.

- [ ] **Step 1: Document voice commands, `cb` and the protocol**

In `README.md`:

In the `## Repository layout` table, in the `firmware/` row replace `` `question_ui.c` + `question.c` (question pages), `` with `` `question_ui.c` + `question.c` (question pages), `voice_ui.c` + `voice.c` (voice capture), ``, and replace the `mac/` row's text with `` Swift package: `claude-board` daemon (Unix socket, CoreBluetooth, on-device dictation, tmux typing) and `claude-board-hook` (Claude Code hook), the `cb` launcher (Claude Code inside tmux), plus install scripts ``.

In the `## BLE protocol` table:
- in the `…0011` row replace `up to 4 pages and 4 options). See` with ``up to 4 pages and 4 options), 8 voice (id = the board's voice id; `<p\|f\|x\|k>\ntext`: live transcript, final transcript (exactly what Send types, at most 300 bytes), error, done); session flags bit2 = voice (the session has a tmux pane). See``;
- in the `…0012` row replace `` `[0 u32][0x21][handle u32 LE]` focus this session |`` with `` `[0 u32][0x21][handle u32 LE]` focus this session; `[voice u32][0x30][purpose u8][target u32 LE]` voice capture start (purpose 0 command → session handle, 1 Other answer → request id with the question index in the high nibble, 2 deny with reason → request id); `[voice u32][0x31\|0x32\|0x33]` stop / cancel / send; bit 7 of a question mask = the spoken Other answer |``;
- add after the `…0012` row:

```markdown
| `…0013` Claude voice | notify, encrypted | Board → Mac, only during a voice capture: the board mic as `[seq u16][predictor i16][index u8][IMA ADPCM 4-bit]`, 16 kHz mono, like `…0002` |
```

In `## Claude companion mode`, replace `The hook passes `$TMUX_PANE` / `$TMUX` on to the daemon when Claude runs inside tmux.` with `The hook passes `$TMUX_PANE` / `$TMUX` (and, inside tmux, its process ancestry, so the daemon can later check that the pane still runs that session) on to the daemon. The installer also installs `cb` (see Voice commands).`

Replace `questions or 4 options stay in the terminal, and there is no "Other" free-text row.` with `questions or 4 options stay in the terminal. While the Mac's voice link is up, every page ends with an "Other (speak)" row for a spoken free-text answer (see Voice commands).`

Insert before `**Bluetooth permission.**`:

```markdown
**Voice commands.** Start Claude Code with `cb` instead of `claude` (same arguments): it runs Claude in a tmux
session named after the current folder, or attaches to that session if it is already running (inside tmux it uses
the current pane), and marks the pane so the Mac may type into it. `mac/install.sh` installs `cb` in
`~/.claude-board/bin` and links it into `~/.local/bin` when that folder exists. Remote Control works as usual.

On the Claude screen tap **Speak**, say the command (Vietnamese by default: `VoiceConfig.localeIdentifier` in
`mac/Sources/ClaudeBoardCore/VoiceHub.swift`) and stop talking: recording ends 1.5 s after you stop, when you tap
Stop, or after 30 s. The ring follows your voice and the words appear as you speak. Then the board shows exactly
what will be typed: **Send** types it into the session's tmux pane and presses Enter once (if Claude is working,
it queues like typed input), **Say again** records again, **Cancel** drops it. Transcription runs on the Mac
itself (SpeechAnalyzer dictation; the Vietnamese model downloads once). The board streams its microphone to the
Mac only while recording, and the iPhone translation pauses meanwhile.

- A session not started with `cb` shows Speak greyed out with "Open with cb for voice"; without the Mac there is
  no Speak at all. Nothing heard: "Didn't catch that"; record again or cancel.
- The Mac types only into a pane it can verify: marked by `cb`, still running that session's Claude Code, not in
  copy mode, and only while Claude is not waiting for an answer in the terminal. Otherwise the board says why and
  nothing is typed. Control characters become spaces, the text never starts with `!`, `/` or `#` (Claude Code's
  bash, command and memory modes) and is at most 300 bytes.
- **Other** answers: on a question page tap "Other (speak)", say the answer and tap **Use**; the row shows it,
  selected, and Send on the last page answers as usual (long-press the row to say it again).
  **Deny + why** on a permission request denies it with the spoken reason, which Claude reads.

**Speech permission.** The daemon asks macOS for Speech Recognition the first time it starts (its embedded
Info.plist carries the reason). Allow it; if you denied it, enable `claude-board` in System Settings → Privacy &
Security → Speech Recognition. The daemon log says `voice ready (vi_VN)` or why voice is unavailable. To check
dictation without the board: `say -v Linh -o /tmp/vi.aiff "Xin chào" && ~/.claude-board/bin/claude-board --transcribe /tmp/vi.aiff`.
```

In `**Safety rules**`, add after the first bullet:

```markdown
- Voice text is typed, stored as an answer or used as a deny reason only after an explicit Send / Use tap on the
  transcript shown, and typed only into a tmux pane the Mac verified for that session.
```

- [ ] **Step 2: Install the Mac side and flash the board**

```bash
cd mac && swift test 2>&1 | tail -1 && python3 -m unittest test_claude_settings test_cb 2>&1 | tail -1 && bash install.sh
ls -l ~/.claude-board/bin/cb ~/.local/bin/cb 2>&1; tail -5 ~/.claude-board/daemon.log
. ~/esp/esp-idf/export.sh && cd ../firmware && idf.py -p /dev/cu.usbmodem1101 flash monitor
```

Expected: tests pass; `claude-board installed.`; `cb` installed (and linked when `~/.local/bin` exists); the daemon log shows `voice ready (vi_VN)` (or, the first time, a Speech Recognition prompt on the Mac: **the user allows it**; macOS may also ask for Bluetooth again after the re-signed install — allow); after the board boots, `[ble] ready` then `[ble] voice on`.

- [ ] **Step 3: End-to-end acceptance (user performs, controller watches the logs)**

Setup: `cd ~/some/project-a && cb` in one terminal (tmux session `project-a`), and plain `claude` (no tmux) in `~/some/project-b` in another. Watch `tail -f ~/.claude-board/daemon.log` and the board monitor.

| # | Do | Expect |
|---|---|---|
| 1 | Board PWR x3, tap `project-a`, then PWR x2 | Claude screen for `project-a` with an enabled **Speak** |
| 2 | Tap Speak, say "Liệt kê các tệp trong thư mục này", stop talking | Ring follows the voice, words appear live; ~1.5 s after you stop: "Send this?" + the sentence. Nothing typed in the terminal yet |
| 3 | Send | Board "Sent" / "Sent to project-a"; the sentence appears in Claude's prompt in the tmux pane and is submitted once; Claude answers it. Daemon log `typed N bytes into project-a %…` |
| 4 | While Claude is working on a long task, Speak another command and Send | The text queues like typed input and runs after the current turn |
| 5 | Speak, then Say again, then Cancel | New recording on Say again; Cancel returns to the session view; nothing typed |
| 6 | Speak and say nothing | "Didn't catch that" after ~5 s, no Send |
| 7 | Focus `project-b` (plain `claude`) | Speak greyed out with "Open with cb for voice" |
| 8 | In the `project-a` pane enter tmux copy mode (prefix `[`), then Speak | "Not sent" / "The terminal is in copy mode — nothing sent" right after tapping Speak; nothing typed. Leave copy mode (`q`) |
| 9 | In `project-a`: "Use AskUserQuestion to ask me which database to use, with two options" | Question page with an "Other (speak)" row; tap it, say "SQLite", Use; the row shows "SQLite" selected; Send → Claude continues with SQLite as the answer |
| 10 | In `project-a`: ask Claude to run `npm test` (permission needed) | Deny / Allow / Deny + why; Deny + why, say "dùng pnpm test thay vì npm test", Send → board "Denied"; Claude reads the reason and proposes `pnpm test` |
| 11 | Same as 10, but answer the request in the terminal while the board is listening | The overlay closes, "Answered in the terminal or timed out."; nothing denied twice |
| 12 | With the iPhone translator on and streaming, do a voice command | No subtitles from the board mic while recording; translation resumes afterwards |
| 13 | Board BOOT (translator mode) with the iPhone mic off, wait 10 s | Board log `recording stopped` after the last capture (codec closed); no voice traffic in the daemon log |
| 14 | Mac Bluetooth off and on | Speak disappears while the link is down and comes back after `[ble] voice on` |
| 15 | `/exit` in `project-a`, then `cb` again in the same folder | A fresh tmux session `project-a`; voice commands work again (new pane verified) |

Record any failure with the board log and `~/.claude-board/daemon.log` lines; fix it in the owning task's files with a test first, then re-run the affected rows.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -F - <<'EOF'
README: voice commands, the cb launcher, spoken Other answers and Deny + why, voice protocol

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WLXX4oGi6aSA46zLrBdBvm
EOF
```
