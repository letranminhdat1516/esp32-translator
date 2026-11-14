import SwiftUI

/// 2.3 Chỉ dùng iPhone: the top half faces the other person (rotated 180°, subtitles in their language); the
/// bottom half is yours. The iPhone mic hears them; "Giữ để nói" gives the input to your headset mic while held
/// (ARCHITECTURE §5, routed by the engine).
struct PhoneOnlyView: View {
    let ui: UIState
    let router: AppRouter
    let partials: PartialModel

    var body: some View {
        VStack(spacing: 0) {
            FacingHalf(ui: ui)
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Text(Copy.t("phoneOnly.topHalf"))
                } trailing: {
                    if ui.board != .ready { WarnTag(text: Copy.t("phoneOnly.noBoard")) }
                }
                TheyHeard(ui: ui, partials: partials)
                    .padding(.top, 22)
                Spacer(minLength: 12)
                HoldToTalkButton(held: ui.talkHeld, action: ui.holdToTalk)
                    .padding(.bottom, DS.Space.buttonGap)
                HStack(spacing: DS.Space.buttonGap) {
                    InstrumentButton(Copy.t("phoneOnly.connect"), kind: .secondary, height: DS.Size.buttonCompact) {
                        router.connectBoard()
                    }
                    InstrumentButton(Copy.t(ui.listening ? "live.stop" : "control.start"), height: DS.Size.buttonCompact,
                                     action: ui.startStop)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 18)
            .padding(.bottom, DS.Space.bottom)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(DS.Color.ink)
        .background(DS.Color.stone.ignoresSafeArea())
        // The face runs under the status bar: 390 pt from the top edge, as in the canvas
        .ignoresSafeArea(edges: .top)
        // Dark status bar text would sit unreadable on the dark face, which belongs to the other person anyway
        .statusBarHidden(true)
    }
}

/// The other person's half: dark face, dot grille, the subtitle last sent for them (their language), upside down.
private struct FacingHalf: View {
    let ui: UIState

    private var subtitle: String {
        if !ui.boardSubtitle.isEmpty { return ui.boardSubtitle }
        return ui.lines.filter(\.mine).max { $0.at < $1.at }?.target ?? ""
    }

    var body: some View {
        ZStack {
            DotGrille(dot: DS.Color.dotDim)
            VStack(spacing: 14) {
                Text(Copy.t("phoneOnly.translatedFrom")).ds(.caption, scales: false).foregroundStyle(DS.Color.boardLabel)
                Text(subtitle).ds(.subtitleBig, scales: false).foregroundStyle(DS.Color.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                StatusDot(color: ui.talkHeld ? DS.Color.warnDot : DS.Color.lightBlue,
                          label: Copy.t(ui.talkHeld ? "phoneOnly.wait" : "phoneOnly.speakNow"),
                          labelColor: DS.Color.boardLabel, type: DSType.monoTime.with())
                    .tracking(1.1)
            }
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 390)
        .background(DS.Color.board)
        .rotationEffect(.degrees(180))
        .accessibilityElement(children: .combine)
    }
}

/// "Họ nói": their last phrase in Vietnamese with what they said under it (their partial while nothing is final).
private struct TheyHeard: View {
    let ui: UIState
    let partials: PartialModel

    private var last: UILine? { ui.lines.filter { !$0.mine }.max { $0.at < $1.at } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.t("bubble.theirs")).ds(.monoTag)
            Text(last.map(TranscriptRowText.shown) ?? partials.theirs).ds(.heard)
                .fixedSize(horizontal: false, vertical: true)
            if let src = last?.source {
                Text(src).ds(DSType.small.with()).lineSpacing(0).foregroundStyle(DS.Color.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Push-to-talk: pressed → `action(true)`, released (or the finger slides off) → `action(false)`. VoiceOver users
/// toggle it with a double tap.
private struct HoldToTalkButton: View {
    let held: Bool
    let action: (Bool) -> Void
    @GestureState private var pressing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
        HStack(spacing: 10) {
            Circle().fill(held ? DS.Color.white : DS.Color.blue).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(Copy.t(held ? "phoneOnly.talking" : "phoneOnly.holdToTalk"))
        }
        .ds(DSType.button)
        .foregroundStyle(held ? DS.Color.white : DS.Color.ink)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.buttonCompact)
        .background(held ? DS.Color.blue : Color.clear, in: shape)
        .overlay { if !held { shape.strokeBorder(DS.Color.ink, lineWidth: 1) } }
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
        )
        .onChange(of: pressing) { _, now in action(now) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.t("phoneOnly.holdToTalk"))
        .accessibilityAddTraits(held ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action(!held) }
    }
}
