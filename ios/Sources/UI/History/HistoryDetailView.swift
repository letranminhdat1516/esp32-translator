import SwiftUI

/// One saved conversation, read only. Track C adds share and delete.
struct HistoryDetailView: View {
    let router: AppRouter
    let session: HistorySession?

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                if let s = session { MonoCell(s.languageCode.uppercased(), type: .monoTag, color: DS.Color.ink) }
            }
            ScreenTitle(session?.title ?? "", type: DSType.title2.with(size: 28)).padding(.top, 6)
            if let s = session {
                Text(HistoryFormatting.longDate(s.startedAt) + " \u{00B7} " + Copy.t("history.lines", ["count": String(s.lineCount)]))
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
                                        Text(l.mine ? l.source : l.target).ds(.row)
                                        Text(l.mine ? l.target : l.source).ds(.caption).foregroundStyle(DS.Color.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 18)
            }
            Spacer(minLength: 0)
        }
    }
}
