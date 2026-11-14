import SwiftUI

/// 1.4 Người đối diện nói tiếng gì? Also the language list behind Settings' "Ngôn ngữ" tile and Live's "EN ▾".
/// Picking calls `ui.pickLanguage` (the controller checks and asks for downloads); "Tải" picks and downloads.
struct LanguageView: View {
    enum Mode { case onboarding, pushed, sheet }

    let ui: UIState
    let router: AppRouter
    var mode: Mode = .onboarding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InstrumentScreen {
            switch mode {
            case .onboarding: OnboardingStepBar(step: .language)
            case .pushed: TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: { EmptyView() }
            case .sheet: TopBar { EmptyView() } trailing: {
                    Button(Copy.t("language.close")) { dismiss() }.buttonStyle(.plain).frame(minHeight: DS.Size.minTarget)
                }
            }
            ScreenTitle(Copy.t("lang.title"), type: DSType.title.with()).padding(.top, mode == .onboarding ? 34 : 6)
                .lineSpacing(0)
            Text(Copy.t("lang.body")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            ScrollView { LanguageRows(ui: ui) }
                .scrollBounceBehavior(.basedOnSize)
                // Room for the selected row's 12 pt bleed into the gutter (the scroll view clips)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .padding(.horizontal, -12)
                .padding(.top, 22)
            if mode == .onboarding {
                Spacer(minLength: 12)
                InstrumentButton(Copy.t("lang.start")) { router.finishOnboarding() }
                    .disabled(ui.languageCode == nil)
            }
        }
    }

}

/// The ruled language list (code, name, status) and the online opt-in below it.
struct LanguageRows: View {
    let ui: UIState

    var body: some View {
        RuledList {
            ForEach(ui.offeredPacks, id: \.code) { pack in row(pack) }
        }
        if !ui.onlineCandidates.isEmpty { OnlineOptIn(ui: ui).padding(.top, 18) }
    }

    private func status(_ code: String) -> PackStatus {
        LanguageRowStatus.resolve(code: code, explicit: ui.packStatus[code], session: ui.session, progress: ui.downloadProgress)
    }

    @ViewBuilder
    private func row(_ pack: LanguagePack) -> some View {
        let st = status(pack.code)
        let selected = pack.code == ui.languageCode && st != .unsupported
        let padding: CGFloat = switch st {
        case .notDownloaded: 10
        default: 14
        }
        Button {
            if st != .unsupported { ui.pickLanguage(pack.code) }
        } label: {
            TableRow(verticalPadding: padding, fill: selected ? DS.Color.ink : nil, horizontalBleed: 12) {
                HStack(spacing: 10) {
                    MonoCell(pack.code.uppercased(), type: .monoCode, color: selected ? DS.Color.stone : DS.Color.ink)
                        .tableColumn(40)
                    HStack(spacing: 6) {
                        Text(pack.label).ds(selected ? .rowTitle : .rowName)
                        if ui.onlineCodes.contains(pack.code) {
                            Text(StatusChip.online.text).ds(.monoTime)
                                .accessibilityLabel(StatusChip.online.accessibilityText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailing(st, selected: selected, code: pack.code)
                }
                .foregroundStyle(selected ? DS.Color.stone : st == .unsupported ? DS.Color.muted : DS.Color.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(st == .unsupported)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func trailing(_ st: PackStatus, selected: Bool, code: String) -> some View {
        switch st {
        case .installed:
            StatusDot(color: selected ? DS.Color.lightBlue : DS.Color.blue, label: Copy.t("lang.installed"),
                      labelColor: selected ? DS.Color.stone : DS.Color.ink)
        case let .downloading(p):
            VStack(alignment: .trailing, spacing: 5) {
                Text(p.map { Copy.t("lang.downloading", ["percent": String(Int((ProgressRule.clamped($0) * 100).rounded()))]) }
                     ?? Copy.t("readiness.downloading"))
                    .ds(.caption)
                ProgressRule(fraction: p ?? 0)
            }
            .frame(width: 96)
        case let .notDownloaded(mb):
            Button(mb.map { Copy.t("lang.download", ["size": String($0)]) } ?? Copy.t("lang.downloadNoSize")) {
                ui.pickLanguage(code)
                ui.download()
            }
            .buttonStyle(.instrumentCompact(.secondary, height: 36, radius: DS.Radius.chipButton, type: .buttonSmall))
        case .unsupported:
            Text(Copy.t("lang.unsupported")).ds(.caption)
        }
    }
}

/// Languages that work only with the online recognizer: why, and a switch per language (the old footer).
struct OnlineOptIn: View {
    let ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let why = LanguageFooterText.why(missing: ui.onlineCandidates) {
                Text(why).ds(.caption).foregroundStyle(DS.Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text(LanguageFooterText.optInTitle).ds(.bodyBold)
            Text(LanguageFooterText.optInNote).ds(.caption).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ui.onlineCandidates, id: \.code) { pack in
                Toggle(isOn: Binding(get: { ui.onlineAllowed.contains(pack.code) },
                                     set: { ui.setOnlineAllowed(pack.code, $0) })) {
                    Text(pack.label).ds(.body).frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.instrument)
            }
        }
    }
}
