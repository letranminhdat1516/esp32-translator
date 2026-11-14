import SwiftUI

/// One saved conversation: the full transcript, share as text, delete.
struct HistoryDetailView: View {
    let router: AppRouter
    let services: AppServices
    let sessionID: String
    @State private var confirmDelete = false

    private var session: HistorySession? { services.historySessions.first { $0.id == sessionID } }

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                if let s = session {
                    HStack(spacing: 16) {
                        ShareLink(item: s.title + "\n\n" + s.transcript) {
                            Text(Copy.t("history.share")).frame(minHeight: DS.Size.minTarget)
                        }
                        .buttonStyle(.plain)
                        MonoCell(s.languageCode.uppercased(), type: .monoTag, color: DS.Color.ink)
                    }
                }
            }
            ScreenTitle(session?.title ?? "", type: DSType.title2.with(size: 28)).padding(.top, 6)
            if let s = session {
                Text(HistoryFormatting.longDate(s.startedAt) + " \u{00B7} " + HistoryFormatting.time(s.startedAt)
                     + " \u{00B7} " + Copy.t("history.lines", ["count": String(s.lineCount)]))
                    .ds(.caption).foregroundStyle(DS.Color.muted).padding(.top, 8)
                ScrollView {
                    RuledList {
                        ForEach(Array(s.lines.enumerated()), id: \.offset) { _, l in
                            TableRow {
                                HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                                    MonoCell(HistoryFormatting.time(l.at)).tableColumn(48)
                                    MonoCell(Copy.t(l.mine ? "live.mine" : "live.theirs"), type: .monoTag,
                                             color: l.mine ? DS.Color.blueText : DS.Color.ink).tableColumn(40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(l.mine || l.target.isEmpty ? l.source : l.target).ds(.row)
                                        let other = l.mine ? l.target : (l.target.isEmpty ? "" : l.source)
                                        if !other.isEmpty {
                                            Text(other).ds(.caption).foregroundStyle(DS.Color.muted)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, 18)
                Spacer(minLength: 12)
                InstrumentButton(Copy.t("history.deleteOne"), kind: .destructive, height: DS.Size.buttonLow) {
                    confirmDelete = true
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .confirmationDialog(Copy.t("history.deleteOneTitle"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Copy.t("history.delete"), role: .destructive) {
                let id = sessionID
                router.pop()
                Task { await services.deleteHistory(id) }
            }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        } message: {
            Text(Copy.t("history.deleteNote"))
        }
    }
}
