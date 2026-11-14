import SwiftUI

/// 1.1 Chào mừng.
struct WelcomeView: View {
    let router: AppRouter

    var body: some View {
        InstrumentScreen {
            TopBar {
                Text(Copy.t("welcome.brand")).fontWeight(.bold)
            } trailing: {
                Text(Copy.t("welcome.openSource")).foregroundStyle(DS.Color.muted)
            }
            BoardDial(ring: .arc(fromDegrees: 200, sweepDegrees: 140, tint: .blue, inset: 6)) {
                AppLogo(size: 96).accessibilityLabel(Copy.t("welcome.logo"))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            ScreenTitle(Copy.t("welcome.title"), type: .title).padding(.top, 36)
            Text(Copy.t("welcome.body")).ds(.lead).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            RuledList {
                bullet(Copy.t("welcome.point1"))
                bullet(Copy.t("welcome.point2"))
            }
            .padding(.top, 18)
            Spacer(minLength: 16)
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("welcome.start")) { router.next() }
                InstrumentButton(Copy.t("welcome.tryPhone"), kind: .secondary, height: DS.Size.buttonLow) {
                    router.tryWithoutBoard()
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        TableRow {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                SquareBullet().tableColumn(20)
                Text(text).ds(.row).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
