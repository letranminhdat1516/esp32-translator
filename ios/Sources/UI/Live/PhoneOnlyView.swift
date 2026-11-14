import SwiftUI

/// 2.3 Chỉ dùng iPhone: the top half faces the other person (rotated 180°, subtitles in their language); the
/// bottom half is yours. Track B routes the inputs (ARCHITECTURE §5) and adds "Giữ để nói".
struct PhoneOnlyView: View {
    let ui: UIState
    let router: AppRouter

    private var sorted: [UILine] { ui.lines.sorted { $0.at < $1.at } }
    private var lastMine: UILine? { sorted.last { $0.mine } }
    private var lastTheirs: UILine? { sorted.last { !$0.mine } }

    var body: some View {
        VStack(spacing: 0) {
            facing
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Text(Copy.t("phoneOnly.topHalf"))
                } trailing: {
                    if ui.board != .ready { WarnTag(text: Copy.t("phoneOnly.noBoard")) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.t("bubble.theirs")).ds(.monoTag)
                    Text(lastTheirs.map(TranscriptRowText.shown) ?? ui.theirPartial).ds(.heard)
                        .fixedSize(horizontal: false, vertical: true)
                    if let src = lastTheirs?.source {
                        Text(src).ds(DSType.small.with()).lineSpacing(0).foregroundStyle(DS.Color.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
                .padding(.top, 22)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
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
    }

    /// The other person's half: dark face, dot grille, their-language subtitle, upside down.
    private var facing: some View {
        ZStack {
            DotGrille(dot: DS.Color.dotDim)
            VStack(spacing: 14) {
                Text(Copy.t("phoneOnly.translatedFrom")).ds(.caption, scales: false).foregroundStyle(DS.Color.boardLabel)
                Text(lastMine?.target ?? "").ds(.subtitleBig, scales: false).foregroundStyle(DS.Color.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                StatusDot(color: DS.Color.lightBlue, label: Copy.t("phoneOnly.speakNow"), labelColor: DS.Color.boardLabel,
                          type: DSType.monoTime.with())
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
