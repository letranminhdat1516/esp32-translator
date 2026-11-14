import SwiftUI

/// 3.1 Lịch sử: sessions saved on this iPhone, grouped by day, with search. "Sửa" shows a delete button per row
/// (a long press does too); "Xoá toàn bộ lịch sử" asks first.
struct HistoryView: View {
    let router: AppRouter
    let services: AppServices
    /// "Lưu lịch sử" is on (when off, a note says new conversations are not saved).
    var saving = true
    @State private var query = ""
    @State private var editing = false
    @State private var confirmDeleteAll = false
    @State private var pendingDelete: HistorySession?

    private var sessions: [HistorySession] { services.historySessions }
    private var filtered: [HistorySession] { sessions.filter { $0.matches(query) } }

    var body: some View {
        InstrumentScreen {
            TopBar {
                BackLink(title: Copy.t("nav.back")) { router.pop() }
            } trailing: {
                Button(Copy.t(editing ? "history.done" : "history.edit")) { editing.toggle() }
                    .buttonStyle(.plain)
                    .fontWeight(editing ? .bold : nil)
                    .frame(minHeight: DS.Size.minTarget)
                    .disabled(sessions.isEmpty)
            }
            ScreenTitle(Copy.t("history.title")).padding(.top, 6)
            Text(Copy.t("history.localOnly")).ds(.caption).foregroundStyle(DS.Color.muted).padding(.top, 8)
            SearchField(text: $query).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !saving {
                        Text(Copy.t("history.savingOff")).ds(.caption).foregroundStyle(DS.Color.warnText)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
                    }
                    let sections = HistoryFormatting.sections(filtered, now: services.now())
                    if sections.isEmpty {
                        Text(Copy.t(sessions.isEmpty ? "history.empty" : "history.noMatch")).ds(.small)
                            .foregroundStyle(DS.Color.muted).padding(.top, 24)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.title) { i, section in
                        SectionHeader(section.title).padding(.top, i == 0 ? 24 : 22)
                        RuledList {
                            ForEach(section.sessions) { s in
                                Button { if !editing { router.push(.historyDetail(s.id)) } } label: { row(s) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(Copy.t("history.delete"), role: .destructive) { pendingDelete = s }
                                    }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
            Spacer(minLength: 12)
            InstrumentButton(Copy.t("history.deleteAll"), kind: .destructive, height: DS.Size.buttonLow) {
                confirmDeleteAll = true
            }
            .disabled(sessions.isEmpty)
        }
        .task { await services.refresh() }
        .confirmationDialog(Copy.t("history.deleteAllTitle"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button(Copy.t("history.deleteAll"), role: .destructive) {
                editing = false
                Task { await services.deleteAllHistory() }
            }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        } message: {
            Text(Copy.t("history.deleteNote"))
        }
        .confirmationDialog(Copy.t("history.deleteOneTitle"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { s in
            Button(Copy.t("history.delete"), role: .destructive) { delete(s) }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        } message: { s in
            Text(s.title)
        }
    }

    private func delete(_ s: HistorySession) {
        Task {
            await services.deleteHistory(s.id)
            if services.historySessions.isEmpty { editing = false }
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
                .accessibilityElement(children: .combine)
                if editing {
                    // Deleting a single conversation still asks (it cannot be undone)
                    Button { pendingDelete = s } label: {
                        Text(Copy.t("history.delete")).ds(.label).foregroundStyle(DS.Color.warnText)
                            .frame(minWidth: DS.Size.minTarget, minHeight: DS.Size.minTarget, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.t("history.deleteA11y", ["title": s.title]))
                } else {
                    MonoCell(s.languageCode.uppercased(), type: .monoTag, color: DS.Color.ink)
                        .tableColumn(36, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
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
                .submitLabel(.search)
                .accessibilityLabel(Copy.t("history.search"))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous).strokeBorder(DS.Color.ink, lineWidth: 1))
    }
}
