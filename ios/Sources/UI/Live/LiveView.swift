import SwiftUI

/// 2.1 Đang dịch: status and language, the board dial with the live subtitle, the transcript, Lịch sử · Dừng ·
/// Cài đặt. Before the session runs, the readiness panel takes the transcript's place.
struct LiveView: View {
    let ui: UIState
    @Bindable var router: AppRouter
    @Bindable var services: AppServices

    private var session: SessionState { ui.session ?? .loading }
    private var running: Bool { ReadinessKind.of(session) == .none }

    var body: some View {
        InstrumentScreen {
            LiveTopBar(ui: ui) { router.sheet = .language }
            if ui.ttsVoiceMissing {
                WarningBox(text: Copy.t("banner.text"), actionTitle: Copy.t("banner.open"), action: ui.openTtsSettings)
                    .padding(.top, 10)
            }
            if running {
                LiveDial(ui: ui, level: services.level)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                if ui.lines.isEmpty {
                    // Reads the partials only while there are no lines (the hint gives way to the first partial)
                    EmptyOrPartials(ui: ui, partials: services.partials, selectedID: $services.selectedLineID)
                } else {
                    transcript
                }
            } else {
                ReadinessView(ui: ui, state: session).padding(.top, 20)
            }
            LiveControls(ui: ui, running: running, history: { router.push(.history) },
                         settings: { router.push(.settings) })
                .padding(.top, 12)
        }
        .onChange(of: running) { _, on in if !on { services.selectedLineID = nil } }
        .confirmationDialog(Copy.t("dialog.clearTitle"), isPresented: $router.confirmClear, titleVisibility: .visible) {
            Button(Copy.t("dialog.clearConfirm"), role: .destructive) { ui.clear() }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        }
    }
}

extension LiveView {
    private var transcript: some View {
        LiveTranscript(ui: ui, lines: ui.lines.sorted { $0.at < $1.at }, partials: services.partials,
                       selectedID: $services.selectedLineID)
            .contextMenu {
                Button(Copy.t("menu.clear"), role: .destructive) { router.confirmClear = true }
            }
    }
}

/// The transcript with the line actions bound to the screen model's intents.
private struct LiveTranscript: View {
    let ui: UIState
    let lines: [UILine]
    let partials: PartialModel
    @Binding var selectedID: String?

    var body: some View {
        TranscriptView(lines: lines, partials: partials, selectedID: $selectedID,
                       onReplay: { ui.replayLine($0) },
                       onEdit: { ui.editLine($0, $1) },
                       onReport: { ui.reportLine($0) })
    }
}

/// No finished line yet: the hint, or the transcript as soon as a partial phrase comes in.
private struct EmptyOrPartials: View {
    let ui: UIState
    let partials: PartialModel
    @Binding var selectedID: String?

    var body: some View {
        if partials.theirs.isEmpty && partials.mine.isEmpty {
            EmptyHint(listening: ui.listening)
            Spacer(minLength: 16)
        } else {
            LiveTranscript(ui: ui, lines: [], partials: partials, selectedID: $selectedID)
        }
    }
}

/// "● Đang nghe" + chips · "VI | EN ▾".
struct LiveTopBar: View {
    let ui: UIState
    let changeLanguage: () -> Void

    var body: some View {
        TopBar {
            HStack(spacing: 10) {
                StatusDot(color: ui.listening ? DS.Color.blue : DS.Color.muted,
                          label: Copy.t(ui.listening ? "status.listening" : "status.waiting"))
                ForEach(ui.chips, id: \.self) { chip in
                    Text(chip.text).ds(.monoTime).foregroundStyle(DS.Color.muted)
                        .accessibilityLabel(chip.accessibilityText)
                }
            }
        } trailing: {
            Button(action: changeLanguage) {
                LanguageSegment(home: Copy.t("live.home"), other: (ui.languageCode ?? "en").uppercased())
            }
            .buttonStyle(.plain)
            .disabled(ui.offeredPacks.isEmpty)
            .accessibilityLabel(Copy.t("live.changeLanguage"))
            .accessibilityValue(Copy.t("header.pair", ["label": ui.languageLabel]))
        }
    }
}

/// The board dial: the level ring while listening, "Board đang hiện" and the subtitle on the board.
private struct LiveDial: View {
    let ui: UIState
    let level: LevelModel

    var body: some View {
        BoardDial(ring: ui.listening && ui.boardMicOn ? .level(level, tint: .blue) : .none) {
            VStack(spacing: 8) {
                Text(Copy.t(ui.board == .ready ? "live.boardShowing" : boardStateKey))
                    .ds(.caption, scales: false).foregroundStyle(DS.Color.boardLabel)
                if !ui.boardSubtitle.isEmpty {
                    Text(ui.boardSubtitle).ds(.dial, scales: false).foregroundStyle(DS.Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 176)
            .accessibilityElement(children: .combine)
        }
    }

    private var boardStateKey: String {
        switch ui.board {
        case .off: "board.off"
        case .scanning: "board.scanning"
        case .connecting: "board.connecting"
        case .ready: "board.ready"
        }
    }
}

private struct EmptyHint: View {
    let listening: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Copy.t(listening ? "hint.listening" : "hint.idle")).ds(.rowTitle)
            Text(Copy.t("hint.body")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
    }
}

/// Lịch sử (60×60) · Dừng / Bắt đầu nghe · Cài đặt (60×60).
private struct LiveControls: View {
    let ui: UIState
    let running: Bool
    let history: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.buttonGap) {
            InstrumentIconButton(label: Copy.t("live.history"), action: history) { DSIconView(icon: .list) }
            Button(action: ui.startStop) {
                HStack(spacing: 10) {
                    if ui.listening {
                        Rectangle().fill(DS.Color.stone).frame(width: 10, height: 10).accessibilityHidden(true)
                    }
                    Text(Copy.t(ui.listening ? "live.stop" : "control.start"))
                }
            }
            .buttonStyle(.instrument())
            .disabled(!running)
            .accessibilityLabel(Copy.t(ui.listening ? "control.stop" : "control.start"))
            InstrumentIconButton(label: Copy.t("settings.label"), action: settings) { DSIconView(icon: .sliders) }
        }
    }
}
