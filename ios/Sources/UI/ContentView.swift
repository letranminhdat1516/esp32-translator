import SwiftUI

/// "Phụ đề" style: black, text first, one blue accent (the board's) that lights only while listening.
enum Palette {
    static let ground = Color.black
    static let surface = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255)
    static let text = Color(red: 0xE3 / 255, green: 0xEA / 255, blue: 0xF0 / 255)
    static let muted = Color(red: 0x8A / 255, green: 0x91 / 255, blue: 0x9C / 255)
    static let faint = Color(red: 0x5E / 255, green: 0x64 / 255, blue: 0x6D / 255)
    static let accent = Color(red: 0x1E / 255, green: 0x6F / 255, blue: 0xD9 / 255)
    static let accentLight = Color(red: 0x4C / 255, green: 0x8F / 255, blue: 0xE8 / 255)
}

/// What the conversation part of the screen shows, from the `UIState` the conversation controller fills.
private struct Live {
    var running: Bool
    var listening: Bool
    var hasHistory: Bool
    var board: BoardState
    var boardMicOn: Bool
    var lines: [UILine]
    var theirPartial: String
    var myPartial: String
    var label: String
    var chips: [StatusChip]
}

struct ContentView: View {
    /// Filled by the conversation controller (fields and intents).
    let ui: UIState
    @State private var confirmClear = false
    @State private var showLanguages = false
    @State private var showGlossary = false

    @MainActor init(ui: UIState) {
        self.ui = ui
    }

    /// `loading` until the controller has set the session.
    private var session: SessionState { ui.session ?? .loading }

    private var live: Live {
        Live(running: ReadinessKind.of(session) == .none, listening: ui.listening, hasHistory: ui.hasHistory,
             board: ui.board, boardMicOn: ui.boardMicOn, lines: ui.lines.sorted { $0.at < $1.at },
             theirPartial: ui.theirPartial, myPartial: ui.myPartial, label: ui.languageLabel, chips: ui.chips)
    }

    var body: some View {
        let live = live
        VStack(spacing: 0) {
            Header(live: live, ui: ui, confirmClear: $confirmClear,
                   showLanguages: $showLanguages, showGlossary: $showGlossary)
            if ui.ttsVoiceMissing { TtsBanner(open: ui.openTtsSettings) }
            content(live)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLanguages) { LanguageSheet(ui: ui) }
        .sheet(isPresented: $showGlossary) { GlossaryView(ui: ui) }
        // The trash sits next to the listen button: a stray tap must not wipe the conversation
        .confirmationDialog(Copy.t("dialog.clearTitle"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(Copy.t("dialog.clearConfirm"), role: .destructive) { ui.clear() }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(_ live: Live) -> some View {
        if ReadinessKind.of(session) == .none {
            conversation(live)
        } else {
            ReadinessView(ui: ui, state: session)
        }
    }

    @ViewBuilder
    private func conversation(_ live: Live) -> some View {
        ConversationView(live: live)
        ControlBar(live: live, confirmClear: $confirmClear, startStop: ui.startStop, toggleBoardMic: ui.toggleBoardMic)
    }
}

/// The Vietnamese voice is missing: translations show as text until it is installed.
private struct TtsBanner: View {
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.slash").foregroundStyle(Palette.accentLight)
            Text(Copy.t("banner.text"))
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: open) {
                Text(Copy.t("banner.open"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Palette.accent, in: Capsule())
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .buttonStyle(.plain)
    }
}

/// Language pair, settings, and one status line: listening · board, then the chips
private struct Header: View {
    let live: Live
    let ui: UIState
    @Binding var confirmClear: Bool
    @Binding var showLanguages: Bool
    @Binding var showGlossary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { showLanguages = true } label: {
                    HStack(spacing: 8) {
                        Text(Copy.t("header.home"))
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.muted)
                        Text(live.label)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Palette.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                // Without a controller there is nothing to pick yet: the pair stays English
                .disabled(ui.offeredPacks.isEmpty)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.t("header.pair", ["label": live.label]))
                .accessibilityAddTraits(.isButton)
                Spacer()
                Menu {
                    Button(Copy.t("menu.languages"), systemImage: "globe") { showLanguages = true }
                        .disabled(ui.offeredPacks.isEmpty)
                    // Without a controller the glossary has nothing to edit
                    if ui.session != nil {
                        Button(Copy.t("menu.glossary"), systemImage: "character.book.closed") { showGlossary = true }
                    }
                    // The phone only talks to the board it paired with first: a new board needs this
                    Button(Copy.t("menu.forgetBoard"), systemImage: "antenna.radiowaves.left.and.right.slash") {
                        ui.forgetBoard()
                    }
                    Button(Copy.t("menu.clear"), systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(!live.running || !live.hasHistory)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                        .background(Palette.surface, in: Circle())
                }
                .accessibilityLabel(Copy.t("settings.label"))
            }
            FlowLayout(spacing: 8, runSpacing: 6) {
                HStack(spacing: 8) {
                Circle()
                    .fill(live.listening ? Palette.accentLight : Palette.faint)
                    .frame(width: 8, height: 8)
                Text(Copy.t(live.listening ? "status.listening" : "status.waiting"))
                    .fontWeight(.semibold)
                    .foregroundStyle(live.listening ? Palette.text : Palette.muted)
                }
                Text("· \(boardText)").foregroundStyle(Palette.muted)
                ForEach(live.chips, id: \.self) { chip in
                    ChipView(text: chip.text).accessibilityLabel(chip.accessibilityText)
                }
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var boardText: String {
        switch live.board {
        case .off: Copy.t("board.off")
        case .scanning: Copy.t("board.scanning")
        case .connecting: Copy.t("board.connecting")
        case .ready: Copy.t(live.boardMicOn ? "board.ready" : "board.readyMicOff")
        }
    }
}

/// Both sides in one stream, oldest first: their lines on the left, yours on the right
private struct ConversationView: View {
    let live: Live

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 26) {
                    if live.lines.isEmpty && live.theirPartial.isEmpty && live.myPartial.isEmpty {
                        EmptyHint(listening: live.listening)
                    }
                    ForEach(live.lines) { line in
                        Bubble(label: Copy.t(line.mine ? "bubble.mine" : "bubble.theirs"), source: line.source,
                               target: line.target, mine: line.mine, unclear: line.unclear)
                            .id(line.id)
                    }
                    if !live.theirPartial.isEmpty {
                        PartialLine(text: live.theirPartial, mine: false).id("theirPartial")
                    }
                    if !live.myPartial.isEmpty {
                        PartialLine(text: live.myPartial, mine: true).id("myPartial")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: live.lines.last?.target) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: live.theirPartial) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: live.myPartial) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct Bubble: View {
    let label: String
    let source: String
    let target: String
    let mine: Bool
    let unclear: Bool

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(source).font(.system(size: 14)).foregroundStyle(Palette.muted)
            if !target.isEmpty {
                Text(target)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(unclear ? Palette.faint : Palette.text)
            }
        }
        .multilineTextAlignment(mine ? .trailing : .leading)
        .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PartialLine: View {
    let text: String
    let mine: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .italic()
            .foregroundStyle(Palette.faint)
            .multilineTextAlignment(mine ? .trailing : .leading)
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

private struct EmptyHint: View {
    let listening: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(Copy.t(listening ? "hint.listening" : "hint.idle"))
                .font(.system(size: 17, weight: .semibold))
            Text(Copy.t("hint.body"))
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
        .padding(.horizontal, 12)
    }
}

/// Board mic · listen / stop · clear
private struct ControlBar: View {
    let live: Live
    @Binding var confirmClear: Bool
    let startStop: () -> Void
    let toggleBoardMic: () -> Void

    var body: some View {
        HStack {
            Button(action: toggleBoardMic) {
                Image(systemName: live.boardMicOn ? "mic" : "mic.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(live.boardMicOn ? Palette.text : Palette.muted)
                    .frame(width: 52, height: 52)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(live.boardMicOn ? Palette.accent : .clear, lineWidth: 2))
            }
            .disabled(live.board != .ready)
            .accessibilityLabel(Copy.t(live.boardMicOn ? "control.micOff" : "control.micOn"))
            Spacer()
            Button(action: startStop) {
                // The header already says "Đang nghe": the button says what a tap does
                Label(Copy.t(live.listening ? "control.stop" : "control.start"),
                      systemImage: live.listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    .background(live.listening ? Palette.accent : Palette.surface, in: Capsule())
            }
            .disabled(!live.running)
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 52, height: 52)
                    .background(Palette.surface, in: Circle())
            }
            .disabled(!live.running || !live.hasHistory)
            .accessibilityLabel(Copy.t("control.clear"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

#if DEBUG
/// The controller-driven screen without an engine, for the previews.
private struct UIStatePreview: View {
    let ui: UIState
    @State private var b = false
    @State private var c = false
    @State private var d = false

    var body: some View {
        let live = Live(running: true, listening: ui.listening, hasHistory: ui.hasHistory, board: ui.board,
                        boardMicOn: ui.boardMicOn, lines: ui.lines.sorted { $0.at < $1.at },
                        theirPartial: ui.theirPartial, myPartial: ui.myPartial, label: ui.languageLabel,
                        chips: ui.chips)
        VStack(spacing: 0) {
            Header(live: live, ui: ui, confirmClear: $b, showLanguages: $c, showGlossary: $d)
            if ui.ttsVoiceMissing { TtsBanner(open: ui.openTtsSettings) }
            ConversationView(live: live)
            ControlBar(live: live, confirmClear: $b, startStop: ui.startStop, toggleBoardMic: ui.toggleBoardMic)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

#Preview("Running with chips and banner") { UIStatePreview(ui: .sampleRunning()) }
#Preview("Running, board connected") {
    UIStatePreview(ui: {
        let ui = UIState.sampleRunning()
        ui.board = .ready
        ui.online = false
        ui.micRoute = .headset
        ui.ttsVoiceMissing = false
        return ui
    }())
}
#endif

/// Children flow left to right and wrap to the next line (the Dart `Wrap`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = place(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, origin) in place(bounds.width, subviews).origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(_ maxWidth: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, width, y + rowHeight)
    }
}
