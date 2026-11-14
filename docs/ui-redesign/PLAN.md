# UI redesign plan (branch `ui-redesign`)

Read `ARCHITECTURE.md` first. The canvas sources are in `docs/ui-redesign/canvas/` (one `.dc.html` per
screen, exact values).

## Phase 0: foundation (serial, one owner)
| Task | Done when |
|---|---|
| 0.1 Fonts in bundle (`UIAppFonts`), `DesignSystem/` tokens + all components from ARCHITECTURE §2 | Components render in demo mode; values match the canvas |
| 0.2 Demo mode (`-demo <screen>`) with fakes + seeded sample data; `ios/Tools/snap.sh` | `snap.sh welcome live settings` writes PNGs from the iPhone 17 Pro simulator |
| 0.3 Skeleton: `RootView`/`AppRouter`, empty view files for every screen, `Features/` stubs, `Shared/` attributes, widget target in `project.yml`, `UILine.audioRange` | `swift test` green; device build and simulator build green; every later track only fills its own files |

## Phase 1: parallel tracks (each in its own worktree, owns only its files)
| Track | Files | Done when |
|---|---|---|
| A Onboarding | `UI/Onboarding/**`, `PairingModel.swift` (+ tests) | Welcome, Permissions (real permission state + requests), Pair (scan, system dialog, pin on authenticated read; current firmware fallback), Language (packs, download progress, unsupported) match the canvas; snapshots |
| B Live | `UI/Live/**`, `LevelModel`/`PartialModel` wiring in `ConversationController` (narrow edits) | LiveView with BoardDial live subtitle, transcript, line actions (Nghe lại, Sửa, Báo dịch sai), stop; BoardLost overlay; PhoneOnly (input routing per §5); no transcript re-render on level change (test); snapshots |
| C Data screens | `UI/History/**`, `UI/Settings/**`, `UI/Glossary/**`, `UI/Sharing/**`, `HistoryStore`, `FeedbackQueue`, `AudioClipRecorder` (+ tests) | Persisted history (batched, gated, excluded from backup), settings wired, glossary restyled, sharing review + WAV/JSON export; snapshots |
| D Live Activity | `ios/Widgets/**`, `Shared/**`, `LiveActivityController` (+ tests for coalescing) | Activity starts/updates/ends from the controller, intents stop/toggle; widget + extension build |
| E Firmware pairing | `firmware/**`, `sim/**` | Numeric comparison per ARCHITECTURE §4, protected characteristics, board code screen with Đúng/Sai, host tests, simulator shot; `idf.py build` green; **not flashed** |

## Phase 2: integration (serial)
1. Merge A–E in order D, C, A, B, E; resolve `UIState`/`ConversationController` overlaps.
2. Full `swift test`, device build, simulator snapshots of all 12 screens → `docs/ui-redesign/shots/`, compare with canvas, fix gaps.
3. Independent review (code-review skill) of the branch; fix critical/important.
4. README: screens, demo mode, pairing, phone-only limits, data export. Push `ui-redesign`.
