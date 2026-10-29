import SwiftUI

// Port of app/lib/ui/language_sheet.dart, plus the footer of ARCHITECTURE §6 (why a language is missing, and the
// online opt-in).

/// Bottom sheet content: the offered languages, the current one ticked. Persisting the pick is the caller's job.
struct LanguageSheet: View {
    var ui: UIState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.t("language.sheetTitle"))
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LanguageList(ui: ui, currentCode: ui.languageCode) { code in
                    dismiss()
                    ui.pickLanguage(code)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.surface)
        .preferredColorScheme(.dark)
    }
}

/// The list itself, shared with the "Chọn ngôn ngữ" step of the readiness view.
struct LanguageList: View {
    var ui: UIState
    var currentCode: String?
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ui.offeredPacks, id: \.code) { pack in
                Button { onPick(pack.code) } label: { row(pack) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(pack.code == currentCode ? .isSelected : [])
            }
            LanguageFooter(ui: ui)
        }
        .padding(.bottom, 12)
    }

    private func row(_ pack: LanguagePack) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(pack.label).font(.system(size: 17, weight: .semibold))
                    if ui.onlineCodes.contains(pack.code) { ChipView(text: StatusChip.online.text) }
                }
                if pack.labelLatin != pack.label {
                    Text(pack.labelLatin).font(.system(size: 14)).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            if pack.code == currentCode {
                Image(systemName: "checkmark").foregroundStyle(Palette.accentLight)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Why some languages are missing, with a switch per language to allow the online recognizer for it.
struct LanguageFooter: View {
    var ui: UIState

    var body: some View {
        if let why = LanguageFooterText.why(missing: ui.onlineCandidates) {
            VStack(alignment: .leading, spacing: 10) {
                Text(why).font(.system(size: 13)).foregroundStyle(Palette.muted)
                Text(LanguageFooterText.optInTitle).font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                Text(LanguageFooterText.optInNote).font(.system(size: 13)).foregroundStyle(Palette.muted)
                ForEach(ui.onlineCandidates, id: \.code) { pack in
                    Toggle(isOn: Binding(
                        get: { ui.onlineAllowed.contains(pack.code) },
                        set: { ui.setOnlineAllowed(pack.code, $0) }
                    )) {
                        Text(pack.label).font(.system(size: 15))
                    }
                    .tint(Palette.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }
}

/// A small rounded mark: "online", "mic điện thoại", "không có board".
struct ChipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.accentLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.accent.opacity(0.18), in: Capsule())
    }
}

#if DEBUG
#Preview("Language sheet") {
    LanguageSheet(ui: .sampleChoosing())
}

#Preview("Language sheet, online opt-in") {
    LanguageSheet(ui: .sampleOnlineOptIn())
}
#endif
