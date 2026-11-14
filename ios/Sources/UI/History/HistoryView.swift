import SwiftUI

/// 3.1 Lịch sử: sessions saved on this iPhone, grouped by day, with search. Track C loads them from the
/// `HistoryStore` and wires search, edit and delete.
struct HistoryView: View {
    let router: AppRouter
    let sessions: [HistorySession]
    let now: Date
    var deleteAll: () -> Void = {}
    @State private var query = ""
    @State private var confirmDelete = false

    private var filtered: [HistorySession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in s.title.localizedCaseInsensitiveContains(q)
            || s.lines.contains { $0.source.localizedCaseInsensitiveContains(q) || $0.target.localizedCaseInsensitiveContains(q) } }
    }

    var body: some View {
        InstrumentScreen {
            TopBar {
                BackLink(title: Copy.t("nav.back")) { router.pop() }
            } trailing: {
                Button(Copy.t("history.edit")) {}.buttonStyle(.plain).frame(minHeight: DS.Size.minTarget)
            }
            ScreenTitle(Copy.t("history.title")).padding(.top, 6)
            Text(Copy.t("history.localOnly")).ds(.caption).foregroundStyle(DS.Color.muted).padding(.top, 8)
            SearchField(text: $query).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let sections = HistoryFormatting.sections(filtered, now: now)
                    if sections.isEmpty {
                        Text(Copy.t("history.empty")).ds(.small).foregroundStyle(DS.Color.muted).padding(.top, 24)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.title) { i, section in
                        SectionHeader(section.title).padding(.top, i == 0 ? 24 : 22)
                        RuledList {
                            ForEach(section.sessions) { s in
                                Button { router.push(.historyDetail(s.id)) } label: { row(s) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 12)
            InstrumentButton(Copy.t("history.deleteAll"), kind: .destructive, height: DS.Size.buttonLow) { confirmDelete = true }
                .disabled(sessions.isEmpty)
        }
        .confirmationDialog(Copy.t("history.deleteAll"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Copy.t("dialog.clearConfirm"), role: .destructive, action: deleteAll)
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        }
    }

    private func row(_ s: HistorySession) -> some View {
        TableRow(verticalPadding: 13) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                MonoCell(HistoryFormatting.time(s.startedAt)).tableColumn(48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).ds(.bodyBold).lineLimit(2)
                    Text(Copy.t("history.lines", ["count": String(s.lineCount)])).ds(.caption).foregroundStyle(DS.Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MonoCell(s.languageCode.uppercased(), type: .monoTag, color: DS.Color.ink).tableColumn(36, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 46 pt outlined search field.
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            DSIconView(icon: .search, size: 18, lineWidth: 1.8)
            TextField("", text: $text, prompt: Text(Copy.t("history.search")).foregroundStyle(DS.Color.muted))
                .ds(DSType.body.with(size: 15))
                .accessibilityLabel(Copy.t("history.search"))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous).strokeBorder(DS.Color.ink, lineWidth: 1))
    }
}
