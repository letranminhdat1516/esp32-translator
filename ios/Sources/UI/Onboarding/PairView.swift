import SwiftUI

/// 1.3 Ghép board. The board shows a 6-digit code with Đúng/Sai and iOS shows the same digits in its own dialog
/// (ARCHITECTURE §4); the app shows no code of its own. Deviation from the canvas (4-digit code in the dial, "Không
/// đúng"/"Đúng, ghép board"): the dial shows where the flow is (looking, compare the codes, paired, failed), the
/// board row carries the waiting progress, and the buttons are "Thử lại" / "Tiếp tục" / "Dùng thử bằng iPhone".
struct PairView: View {
    let router: AppRouter
    let pairing: any PairingModeling
    /// When the current confirmation started (the 30 s the board waits for an answer).
    @State private var confirmStart: Date?

    var body: some View {
        let s = PairDisplay(pairing.state)
        InstrumentScreen {
            OnboardingStepBar(step: .pair)
            dial(s)
                .frame(maxWidth: .infinity)
                .padding(.top, 34)
            Text(Copy.t(s.noteKey)).ds(.caption).foregroundStyle(DS.Color.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
            ScreenTitle(Copy.t("pair.title"), type: .title).padding(.top, 26)
            if s.legacy {
                // An old-firmware board: pinned only on "Vẫn ghép" (README "BLE pairing")
                WarningBox(text: Copy.t(s.bodyKey)).padding(.top, 10)
            } else {
                Text(Copy.t(s.bodyKey)).ds(.paragraph)
                    .foregroundStyle(s.failed ? DS.Color.warnText : DS.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if let hint = s.dialogHintKey {
                Text(Copy.t(hint)).ds(.caption).foregroundStyle(DS.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            RuledList { boardRow(s) }
                .padding(.top, 18)
            Spacer(minLength: 16)
            buttons(s)
        }
        .onAppear { pairing.start() }
        .onChange(of: s.confirming, initial: true) { _, confirming in confirmStart = confirming ? Date() : nil }
        .animation(.easeOut(duration: 0.2), value: pairing.state)
    }

    // MARK: Parts

    @ViewBuilder
    private func dial(_ s: PairDisplay) -> some View {
        if let start = confirmStart, s.confirming {
            TimelineView(.periodic(from: start, by: 0.5)) { ctx in
                BoardDial(ring: .arc(fromDegrees: 0, sweepDegrees: 360 * Self.remaining(since: start, now: ctx.date),
                                     tint: .blue, inset: 6)) { dialFace(s) }
            }
        } else {
            BoardDial(ring: s.paired ? .arc(fromDegrees: 0, sweepDegrees: 360, tint: .blue, inset: 6)
                      : s.failed || s.legacy ? .arc(fromDegrees: 0, sweepDegrees: 360, tint: .warn, inset: 6)
                      : .arc(fromDegrees: 200, sweepDegrees: 140, tint: .blue, inset: 6)) { dialFace(s) }
        }
    }

    private func dialFace(_ s: PairDisplay) -> some View {
        VStack(spacing: 8) {
            Text(Copy.t(s.kickerKey)).ds(DSType.monoKicker.with(), scales: false)
                .tracking(10 * 0.14)
                .foregroundStyle(DS.Color.boardLabel)
            Text(Copy.t(s.dialKey)).ds(.monoCodeBig, scales: false).foregroundStyle(DS.Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.t(s.noteKey))
    }

    private func boardRow(_ s: PairDisplay) -> some View {
        TableRow(verticalPadding: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name ?? Copy.t("pair.scanning")).ds(.bodyBold)
                    if let b = s.battery {
                        MonoCell(Copy.t("pair.battery", ["percent": String(b)]))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if s.confirming, let start = confirmStart {
                    TimelineView(.periodic(from: start, by: 0.5)) { ctx in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(Copy.t("pair.waiting")).ds(.caption)
                            ProgressRule(fraction: Self.remaining(since: start, now: ctx.date))
                        }
                        .frame(width: 132)
                    }
                } else if s.found {
                    Text(Copy.t("pair.connecting")).ds(.caption).foregroundStyle(DS.Color.muted)
                } else if s.paired {
                    StatusDot(color: DS.Color.blue, label: Copy.t("pair.kickerPaired"))
                }
            }
        }
    }

    @ViewBuilder
    private func buttons(_ s: PairDisplay) -> some View {
        if s.paired {
            InstrumentButton(Copy.t("pair.continue")) { router.next() }
        } else if s.legacy {
            HStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("pair.cancelLegacy"), kind: .secondary) { pairing.declineLegacy() }
                InstrumentButton(Copy.t("pair.acceptLegacy")) { pairing.acceptLegacy() }
            }
        } else if s.failed {
            HStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("pair.usePhone"), kind: .secondary) { router.tryWithoutBoard() }
                InstrumentButton(Copy.t("pair.retry")) { pairing.retry() }
            }
        } else {
            InstrumentButton(Copy.t("pair.usePhone"), kind: .secondary, height: DS.Size.buttonLow) {
                router.tryWithoutBoard()
            }
        }
    }

    /// The share of the board's 30 s still left (1 → 0).
    static func remaining(since start: Date, now: Date) -> Double {
        ProgressRule.clamped(1 - now.timeIntervalSince(start) / 30)
    }
}
