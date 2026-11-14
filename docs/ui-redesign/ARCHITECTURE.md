# UI redesign "Nhạc cụ": architecture

Source of truth for the look: the Design canvas "Live Translator redesign", page "App iPhone"
(https://claude.ai/artifact/5gjvUEXVPuNux5UXgB8Xb2). The canvas files are mirrored in
`docs/ui-redesign/canvas/*.dc.html`. Copy every exact value (sizes, colours, paddings, copy) from them.

Decisions taken with the owner (2026-11-15): all 12 screens plus a Live Activity; pairing by code needs
firmware work, which is committed but not flashed; data sharing collects a local queue and exports through
the share sheet (there is no server); work happens on branch `ui-redesign`.

## 1. Goals and budgets

| Budget | Target | How |
|---|---|---|
| Main-thread work per board audio packet | 0 view invalidations | Audio, level and partials live in separate `@Observable` leaf models. A view reads only what it draws |
| Level ring redraw | ≤ 15 Hz, GPU only | `LevelModel` throttled to 66 ms. The ring is a `Canvas` stroke with opacity and width from the level. The dot grille is drawn once (`.drawingGroup()` on a static layer) |
| Transcript | O(visible) | `LazyVStack` in a `ScrollView`, stable `UILine.id`, `Equatable` row views, the partial row separate from the finished rows |
| Live Activity updates | ≤ 1 per 1.5 s, ≤ 4 KB payload | `LiveActivityController` coalesces and sends only the latest phrase pair plus state |
| App launch | No font or JSON work on the first frame | Fonts are registered via `UIAppFonts` (Info.plist); language packs keep loading as today |
| Accessibility | Dynamic Type for body text, VoiceOver labels everywhere, 44 pt targets | Tokens scale with `@ScaledMetric`; mono labels are capped at `.accessibility1` |

## 2. Module layout (all in the app target unless noted)

```
ios/Sources/
  DesignSystem/          NEW. Pure SwiftUI, no app logic; also compiled by the Preview/demo
    Tokens.swift         colours, type scale, spacing, radii (single enum `DS`)
    Fonts.swift          Font helpers: .ds(.title) / .mono(.label); Space Grotesk + JetBrains Mono
    Components/
      InstrumentButton.swift   primary (ink block) / secondary (1px ink outline) / destructive (orange outline)
      BoardDial.swift          the board object: dot grille, bezel shadow rings, level ring, centre content
      TableRow.swift           ruled rows (top rule ink, separators #CFCAC1), mono time/code columns
      StepBar.swift            3-step segmented bar + "Bước n/3"
      InstrumentToggle.swift   square switch (ToggleStyle)
      StatusDot.swift, Tile.swift, ProgressRule.swift, SectionHeader.swift, WarningBox.swift
  Resources/Fonts/       SpaceGrotesk.ttf, JetBrainsMono.ttf (variable, OFL; licences next to them)
  UI/
    Root/RootView.swift          routes: onboarding vs main; sheet/navigation state (AppRouter)
    Onboarding/                  Welcome, Permissions, Pair, Language (+ OnboardingModel)
    Live/                        LiveView (2.1), PhoneOnlyView (2.3), BoardLostView (2.4), TranscriptView
    History/                     HistoryView + HistoryDetailView
    Glossary/                    GlossaryView (restyled; keeps the existing validation)
    Settings/                    SettingsView
    Sharing/                     SharingView (review queue + export)
    UIState.swift, Copy.swift    existing; extended
  Features/              NEW. Logic behind the new screens (unit-tested, no SwiftUI)
    HistoryStore.swift           sessions persisted as JSON in Application Support/History (excluded from backup)
    FeedbackQueue.swift          "Báo dịch sai" items: text + audio clip refs; export bundle builder
    AudioClipRecorder.swift      rolling PCM ring buffers (mine + theirs, 20 s each), clip(range) -> WAV
    LiveActivityController.swift ActivityKit start/update/end with coalescing
    PairingModel.swift           pairing-by-code state machine (app side)
  Shared/                NEW. Compiled into the app AND the widget extension
    TranslatorActivityAttributes.swift
    TranslatorIntents.swift      LiveActivityIntent: stop, toggle board mic (performed in the app process)
ios/Widgets/             NEW target `ESPTranslatorWidgets` (Widget extension): Live Activity + Dynamic Island UI
```

## 3. State and data flow

- `ConversationController` stays the single owner of the conversation (unchanged contract). `UIState` stays
  the screen model. Hot values that change several times a second move out of `UIState` into leaf models,
  so a level change never re-renders the transcript:
  - `LevelModel` (board voice level 0…1, throttled), `PartialModel` (theirPartial/myPartial).
  - `UIState` keeps lines, session, board state, settings and intents.
- `AppRouter` (`@Observable`): `onboardingDone` (UserDefaults `onboarding.done`), the path stack for
  Settings → Glossary/History/Sharing, and sheets.
- Board connection states map to screens: `ready` → LiveView; `scanning/connecting` after having been ready
  → BoardLostView overlay (with "Dùng iPhone trong lúc chờ"); never paired → onboarding Pair.
- History: `ConversationController` already emits finished lines. `HistoryStore.append(line, session:)` runs
  on a background actor and is batched (flush every 2 s and on stop/background). It runs only when the "Lưu
  lịch sử" setting is on (default on). Each session is one file `yyyyMMdd-HHmmss-<lang>.json`.
- Feedback: "Báo dịch sai" on a line → `FeedbackQueue.add(line, clip: recorder.clip(line.audioRange))`.
  Audio is kept only for lines the user flags. The ring buffers hold at most 20 s per side in memory, which
  is overwritten continuously and never written unless flagged. Export = a folder `feedback-<date>/` with
  `items.json` and `NN.wav`, shared via `ShareLink`. Nothing leaves the phone otherwise. The setting
  "Chia sẻ để cải thiện" (default off) gates the flag action's audio capture.
- `UILine` gains `audioRange: ClosedRange<TimeInterval>?` (recognizer result range mapped to the recorder
  clock) and `side`.

## 4. Pairing by code (secure)

Replaces trust-on-first-use with **LE Secure Connections numeric comparison**:
- Firmware: NimBLE `sm_io_cap = DISPLAY_YESNO`, `sm_sc = 1`, `sm_mitm = 1`, bonding on. On
  `BLE_GAP_EVENT_PASSKEY_ACTION` with `BLE_SM_IOACT_NUMCMP`, the board shows the 6-digit code full screen
  with "Đúng"/"Sai" touch buttons and injects the answer (`ble_sm_inject_io`). The translator characteristics
  (text …0003, control …0004, audio CCCD) require an encrypted, authenticated link (`*_ENC | *_AUTHEN`), so
  nothing works until the pair is confirmed. Existing bonds keep working; a bond without MITM forces a
  re-pair once.
- iOS shows its own system dialog with the same 6 digits when the first protected characteristic is
  touched. The app's Pair screen (1.3) explains it ("So mã trên iPhone với mã trên board"). The design's
  4-digit mock becomes 6 digits shown by the board; the app shows no code of its own.
- Board info (`…0005`, open) reports version 2 on firmware that enforces this (same 5-byte layout).
- The app pins the peripheral as `.secure` only when board info says ≥ 2 and an authenticated access succeeded
  (`BoardPin` proof = a successful read of control `…0004`). Old firmware (< 2, or no control characteristic)
  proves nothing: the Pair screen asks ("Vẫn ghép" / "Huỷ", state `legacyConsent`) and only "Vẫn ghép" pins it,
  as `.legacy`. A `.secure` pin that comes back reporting < 2 or without the control characteristic is refused
  and never downgraded; a `.legacy` pin upgrades to `.secure` once the board proves it. Pins saved without a
  level load as `.legacy`.
- Limitation: CoreBluetooth cannot see whether the link is encrypted, so a peripheral claiming version 2 that lets
  the read through unpaired would be pinned `.secure`; the only tell is that iOS shows no pairing dialog, which
  the Pair screen calls out ("iPhone phải hiện hộp thoại ghép kèm mã").
- Firmware is changed and host-tested and the simulator is updated, but it is **not flashed** (owner flashes).

## 5. Phone-only mode (2.3), temporary

iOS has one input route. Phone-only = the iPhone's built-in mic feeds the **theirs** recognizer (session
`preferredInput = builtInMic`, AirPods stay as output); your side is push-to-talk ("Giữ để nói") that
switches the input to the headset mic while held. The top half is rotated 180° for the other person
(subtitles in their language). This is a deliberate simplification, documented in the README.

## 6. Live Activity

- `TranslatorActivityAttributes` (static: language code) + `ContentState` (listening, boardBattery, theirs,
  translation, micOn). Started when a conversation starts, ended on stop or app termination; stale after 8 h.
- The widget uses the same tokens (copied colour constants: the extension does not link the app).
- Buttons use `LiveActivityIntent`s `StopConversationIntent` and `ToggleBoardMicIntent`, run in the app
  process through a shared `IntentBridge` that calls the controller.
- `NSSupportsLiveActivities = YES` in the app Info.plist.

## 7. Verification

- `swift test` (TranslatorCore + EngineTests) for all logic in `Features/` and `DesignSystem` value logic.
- **Demo mode**: launching the app with `-demo <screen>` swaps in `FakeVoiceEngine` + `FakeBoardLink` and
  seeds the canvas sample data, so every screen renders on the iOS Simulator without a board.
  `ios/Tools/snap.sh <screen…>` builds for the simulator, boots an iPhone 17 Pro, launches each screen and
  saves `docs/ui-redesign/shots/<screen>.png`. Shots are compared side by side with the canvas.
- `xcodebuild … generic/platform=iOS` device build (no signing) must succeed. The widget extension builds too.

## 8. Out of scope tonight

The server for shared data, flashing the board, App Store assets, the LLM correction spike (it runs on the
owner's iPhone 17 Pro later), and Android.
