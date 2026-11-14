import SwiftUI

/// The "Báo dịch sai" sheet: `UIState.reportWrong(line)` opens it. With sharing off it first asks to turn sharing on
/// ("Bật chia sẻ" / "Để sau"); then it shows what was heard and translated, takes the corrected text (optional) and
/// adds the report to the local queue reviewed in Chia sẻ dữ liệu.
struct ReportSheet: View {
    let ui: UIState
    let draft: FeedbackDraft
    @State private var expected = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if draft.needsSharing { enablePrompt } else { form }
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.stone)
        .foregroundStyle(DS.Color.ink)
    }

    private var enablePrompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.t("report.enableTitle")).ds(DSType.title2.with(size: 28)).fixedSize(horizontal: false, vertical: true)
            Text(Copy.t("report.enableBody")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            WarningBox(text: Copy.t("sharing.warning")).padding(.top, 16)
            Spacer(minLength: 20)
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("report.enable"), action: ui.enableSharingForFeedback)
                InstrumentButton(Copy.t("report.later"), kind: .secondary, height: DS.Size.buttonLow,
                                 action: ui.cancelFeedback)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.t("report.title")).ds(DSType.title2.with(size: 28))
            RuledList {
                field(Copy.t("report.heard"), draft.line.source)
                if !draft.line.target.isEmpty { field(Copy.t("report.translation"), draft.line.target) }
            }
            .padding(.top, 16)
            Text(Copy.t("report.expected")).ds(.caption).foregroundStyle(DS.Color.muted).padding(.top, 18)
            TextField("", text: $expected, prompt: Text(Copy.t("report.expectedHint")).foregroundStyle(DS.Color.muted),
                      axis: .vertical)
                .ds(.body)
                .lineLimit(1...3)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous)
                    .strokeBorder(DS.Color.ink, lineWidth: 1))
                .padding(.top, 6)
                .accessibilityLabel(Copy.t("report.expected"))
            Text(draft.hasClip ? Copy.t("report.clip", ["seconds": clipSeconds]) : Copy.t("report.noClip"))
                .ds(.caption).foregroundStyle(DS.Color.muted).padding(.top, 10)
            Spacer(minLength: 20)
            Text(Copy.t("report.note")).ds(.caption).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("report.send")) { ui.submitFeedback(expected) }
                InstrumentButton(Copy.t("dialog.cancel"), kind: .secondary, height: DS.Size.buttonLow,
                                 action: ui.cancelFeedback)
            }
        }
    }

    private var clipSeconds: String {
        guard let r = draft.line.audioRange else { return "–" }
        return String(max(1, Int((r.upperBound - r.lowerBound + 2 * DataCoordinator.clipPadding).rounded())))
    }

    private func field(_ label: String, _ value: String) -> some View {
        TableRow(verticalPadding: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).ds(.caption).foregroundStyle(DS.Color.muted)
                Text(value).ds(.bodyBold).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Presents the "Báo dịch sai" sheet while `ui.feedbackDraft` is set (attach once, at the root).
    func feedbackReporting(_ ui: UIState) -> some View {
        sheet(item: Binding(get: { ui.feedbackDraft }, set: { if $0 == nil { ui.cancelFeedback() } })) { draft in
            ReportSheet(ui: ui, draft: draft)
                .presentationDetents([.large])
                .presentationBackground(DS.Color.stone)
        }
    }
}
