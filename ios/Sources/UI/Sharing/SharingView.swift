import SwiftUI

/// 3.4 Chia sẻ dữ liệu: the "Báo dịch sai" queue, choose what to send, export through the share sheet (there is
/// no server). Track C wires the queue, playback and the export bundle.
struct SharingView: View {
    let ui: UIState
    let router: AppRouter
    let items: [FeedbackItem]
    var toggle: (FeedbackItem) -> Void = { _ in }
    var play: (FeedbackItem) -> Void = { _ in }
    var send: () -> Void = {}
    var clearSent: () -> Void = {}

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                Toggle(isOn: Binding(get: { ui.shareToImprove }, set: ui.setShareToImprove)) {
                    Text(Copy.t("sharing.allow"))
                }
                .toggleStyle(.instrument)
            }
            ScreenTitle(Copy.t("sharing.title")).padding(.top, 6)
            Text(Copy.t("sharing.body")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            WarningBox(text: Copy.t("sharing.warning")).padding(.top, 14)
            SectionHeader(Copy.t("sharing.reported", ["count": String(items.count)])).padding(.top, 20)
            ScrollView {
                RuledList {
                    ForEach(items) { item in row(item) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 8)
            Spacer(minLength: 12)
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("sharing.send", ["count": String(InMemoryFeedbackQueue.selectedCount(items))]),
                                 action: send)
                    .disabled(InMemoryFeedbackQueue.selectedCount(items) == 0)
                Button(action: clearSent) {
                    Text(Copy.t("sharing.clearSent")).ds(.button, scales: false).underline()
                        .foregroundStyle(DS.Color.warnText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ item: FeedbackItem) -> some View {
        TableRow(verticalPadding: 12) {
            HStack(spacing: 12) {
                Button { toggle(item) } label: { InstrumentCheckbox(isOn: item.selected).frame(width: 24, height: 44) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.t("sharing.select"))
                    .accessibilityValue(item.selected ? Text(Copy.t("settings.on")) : Text(Copy.t("settings.off")))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.heard + " \u{2192} " + item.expected).ds(DSType.row.with(weight: 700)).lineSpacing(0)
                        .lineLimit(2)
                    Text(subtitle(item)).ds(.caption)
                        .foregroundStyle(item.sensitive ? DS.Color.warnText : DS.Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { play(item) } label: {
                    DSIconView(icon: .play, size: 12)
                        .frame(width: 40, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous)
                            .strokeBorder(DS.Color.ink, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(item.clipFile == nil && item.clipSeconds == nil)
                .accessibilityLabel(Copy.t("sharing.play"))
            }
        }
    }

    private func subtitle(_ item: FeedbackItem) -> String {
        let who = Copy.t(item.mine ? "bubble.mine" : "bubble.theirs")
        if item.sensitive { return who + " \u{00B7} " + Copy.t("sharing.sensitive") }
        if let s = item.clipSeconds { return who + " \u{00B7} " + Copy.t("sharing.seconds", ["seconds": String(Int(s.rounded()))]) }
        return who
    }
}
