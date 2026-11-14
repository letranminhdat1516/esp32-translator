import SwiftUI

/// 1.3 Ghép board. The board shows the code; iOS shows the same digits in its own dialog (ARCHITECTURE §4).
/// Track A drives it from the BLE pairing model.
struct PairView: View {
    let router: AppRouter
    let pairing: any PairingModeling

    var body: some View {
        let s = Display(pairing.state)
        InstrumentScreen {
            OnboardingStepBar(step: .pair)
            BoardDial {
                VStack(spacing: 8) {
                    Text(Copy.t("pair.codeLabel")).ds(DSType.monoKicker.with(), scales: false)
                        .tracking(10 * 0.14)
                        .foregroundStyle(DS.Color.boardLabel)
                    Text(s.code ?? "····").ds(.monoCodeBig, scales: false).foregroundStyle(DS.Color.white)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            Text(Copy.t("pair.codeNote")).ds(.caption).foregroundStyle(DS.Color.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
            ScreenTitle(Copy.t("pair.title"), type: .title).padding(.top, 26)
            Text(Copy.t("pair.body", ["code": s.code ?? ""])).ds(.paragraph).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            RuledList {
                TableRow(verticalPadding: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name ?? Copy.t("pair.scanning")).ds(.bodyBold)
                        if let b = s.battery {
                            MonoCell(Copy.t("pair.battery", ["percent": String(b)]))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 16)
            HStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("pair.reject"), kind: .secondary) { pairing.reject() }
                InstrumentButton(Copy.t("pair.confirm")) {
                    pairing.confirm()
                    router.next()
                }
            }
        }
    }

    private struct Display {
        var name: String?
        var battery: Int?
        var code: String?

        init(_ state: PairingState) {
            switch state {
            case let .found(name, battery): self.name = name; self.battery = battery
            case let .confirming(name, battery, code): self.name = name; self.battery = battery; self.code = code
            case let .paired(name): self.name = name
            default: break
            }
        }
    }
}
