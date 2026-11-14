import SwiftUI

/// 2.2 Màn hình khoá, rendered in-app for demo snapshots: the Dynamic Island in its compact form, the lock-screen
/// clock, and the Live Activity card (the same view the widget extension shows).
struct LockScreenPreview: View {
    let info: TranslatorActivityStatic
    let state: TranslatorActivityState
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ActivityIslandLeading(info: info)
                Spacer()
                ActivityIslandTrailing()
            }
            .padding(.horizontal, 14)
            // Wider than the canvas' 214 pt (290) so "EN→VI" clears the camera cutout the simulator draws on top
            .frame(width: 290, height: 37)
            .background(Color.black, in: Capsule())
            .padding(.top, 11)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Copy.t("activity.island", ["code": info.languageCode.uppercased()]))
            VStack(spacing: 4) {
                Text(HistoryFormatting.longDate(now)).ds(.caption, scales: false).foregroundStyle(DS.Color.lockDate)
                Text(HistoryFormatting.time(now))
                    .font(.ds(DSType(family: .grotesk, size: 92, weight: 500, tracking: -0.04)))
                    .tracking(-0.04 * 92)
                    .foregroundStyle(DS.Color.stone)
            }
            .padding(.top, 60)
            Spacer()
            ActivityLockView(info: info, state: state)
                .background(DS.Color.stone, in: RoundedRectangle(cornerRadius: DS.Radius.activity, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.lockGround.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .statusBarHidden(true)
    }
}
