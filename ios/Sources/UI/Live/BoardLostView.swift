import SwiftUI

/// 2.4 Mất kết nối board: shown when a board that was connected goes away; "Dùng iPhone trong lúc chờ" carries on
/// with phone-only until it is back.
struct BoardLostView: View {
    let ui: UIState
    let router: AppRouter
    /// The clock for "12 giây trước" (demo mode pins it); read every second.
    let now: () -> Date
    var forget: () -> Void

    var body: some View {
        InstrumentScreen {
            TopBar {
                StatusDot(color: DS.Color.warnDot, label: Copy.t("lost.status"), labelColor: DS.Color.warnText)
            } trailing: {
                if let at = ui.boardLostAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(HistoryFormatting.ago(at, now: now()))
                            .foregroundStyle(DS.Color.muted)
                            .monospacedDigit()
                    }
                }
            }
            BoardDial(ring: .arc(fromDegrees: 300, sweepDegrees: 70, tint: .warn), dimmed: true) {
                VStack(spacing: 8) {
                    Text(Copy.t("lost.reconnecting")).ds(.caption, scales: false).foregroundStyle(DS.Color.boardLabel)
                    Text(verbatim: "\u{2026}").ds(.monoEllipsis, scales: false).foregroundStyle(DS.Color.boardFaint)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            ScreenTitle(Copy.t("lost.title"), type: .title2).padding(.top, 30)
            Text(Copy.t("lost.body")).ds(.paragraph).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            RuledList {
                if let b = ui.boardLostBattery {
                    fact(Copy.t("lost.batteryKey"), Copy.t("lost.battery", ["percent": String(b)]))
                }
                fact(Copy.t("lost.tryKey"), Copy.t("lost.try"))
            }
            .padding(.top, 18)
            Spacer(minLength: 16)
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("lost.usePhone")) { router.continueWithPhone() }
                InstrumentButton(Copy.t("lost.forget"), kind: .destructive, height: DS.Size.buttonLow, action: forget)
            }
        }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        TableRow(verticalPadding: 10) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                Text(key).ds(DSType.monoTag).tracking(0.66).tableColumn(110)
                Text(value).ds(DSType.small.with()).lineSpacing(0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
