import SwiftUI

/// 3.2 Cài đặt: board and language tiles, switches, links to the glossary, sharing and voice, "Quên board này".
/// The switches are persisted by `DataCoordinator`; the board tile reads the battery the link reports.
struct SettingsView: View {
    let ui: UIState
    let router: AppRouter
    let appVersion: String
    var forget: () -> Void

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                Text(Copy.t("settings.version", ["version": appVersion])).foregroundStyle(DS.Color.muted)
            }
            ScreenTitle(Copy.t("settings.label")).padding(.top, 6).padding(.bottom, 20)
            HStack(alignment: .top, spacing: DS.Space.buttonGap) {
                Tile(style: .dark, kicker: Copy.t("settings.boardKicker"), value: boardValue, caption: boardCaption)
                Button { router.push(.language) } label: {
                    Tile(style: .outline, kicker: Copy.t("settings.languageKicker"),
                         value: (ui.languageCode ?? "–").uppercased(),
                         caption: Copy.t("settings.languagesInstalled", ["count": String(installedCount)]))
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                RuledList {
                    toggleRow(Copy.t("settings.boardMic"), isOn: ui.boardMicOn) { _ in ui.toggleBoardMic() }
                        .disabled(ui.board != .ready)
                    toggleRow(Copy.t("settings.saveHistory"), isOn: ui.saveHistory, set: ui.setSaveHistory)
                    linkRow(Copy.t("settings.share"), value: Copy.t(ui.shareToImprove ? "settings.on" : "settings.off")) {
                        router.push(.sharing)
                    }
                    linkRow(Copy.t("settings.glossary"),
                            value: Copy.t("glossary.count", ["count": String(ui.glossaryTerms.count)])) {
                        router.push(.glossary)
                    }
                    linkRow(Copy.t("settings.voice"), value: ui.voiceName ?? Copy.t("settings.voiceDefault"),
                            action: ui.openTtsSettings)
                    linkRow(Copy.t("settings.openSource"), value: Copy.t("settings.github"), mono: false) {
                        openURL(Self.sourceURL)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 18)
            Spacer(minLength: 12)
            InstrumentButton(Copy.t("settings.forget"), kind: .destructive, height: 50, action: forget)
        }
    }

    @Environment(\.openURL) private var openURL

    static let sourceURL = URL(string: "https://github.com/letranminhdat1516/esp32-translator")!

    /// Installed languages, Vietnamese included ("Đã tải 2 ngôn ngữ" with English ready).
    private var installedCount: Int {
        1 + ui.offeredPacks.filter {
            LanguageRowStatus.resolve(code: $0.code, explicit: ui.packStatus[$0.code], session: ui.session,
                                      progress: ui.downloadProgress) == .installed
        }.count
    }

    private var boardValue: String {
        guard ui.board == .ready else { return "–" }
        return ui.boardBattery.map { "\($0)%" } ?? "–"
    }

    private var boardCaption: String {
        switch ui.board {
        case .ready:
            let base = Copy.t(ui.boardMicOn ? "settings.boardConnected" : "board.readyMicOff")
            return ui.boardCharging ? base + " \u{00B7} " + Copy.t("settings.charging") : base
        case .off: return Copy.t("board.off")
        case .scanning: return Copy.t("board.scanning")
        case .connecting: return Copy.t("board.connecting")
        }
    }

    private func toggleRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        TableRow(verticalPadding: 0, minHeight: DS.Size.settingsRow) {
            Toggle(isOn: Binding(get: { isOn }, set: set)) {
                Text(title).ds(.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.instrument)
        }
    }

    private func linkRow(_ title: String, value: String, mono: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TableRow(verticalPadding: 0, minHeight: DS.Size.settingsRow) {
                HStack {
                    Text(title).ds(.body)
                    Spacer()
                    Text(value).ds(mono ? .monoValue : .caption).foregroundStyle(DS.Color.muted)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
