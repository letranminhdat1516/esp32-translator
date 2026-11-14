import SwiftUI

/// Both sides in one ruled stream, oldest first, in Vietnamese (their translation, your own words). A tapped line
/// opens its actions; partials are a separate leaf so they never re-render the finished rows.
struct TranscriptView: View {
    let lines: [UILine]
    let ui: UIState
    @Binding var selectedID: String?
    var onReplay: (UILine) -> Void = { _ in }
    var onEdit: (UILine) -> Void = { _ in }
    var onReport: (UILine) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    TranscriptRow(line: line, selected: line.id == selectedID,
                                  separator: !(line.id == selectedID || nextIsSelected(line)))
                        .equatable()
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = selectedID == line.id ? nil : line.id }
                        .overlay(alignment: .bottomLeading) {
                            if line.id == selectedID {
                                LineActions(replay: { onReplay(line) }, edit: { onEdit(line) }, report: { onReport(line) })
                                    .padding(.leading, 48 + 40 + 2 * DS.Space.column)
                                    .padding(.bottom, DS.Space.rowPad)
                            }
                        }
                }
                PartialRows(ui: ui)
            }
            .padding(.top, 1)
            .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
        }
        // Short transcripts sit under the dial; long ones open scrolled to the newest line
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollBounceBehavior(.basedOnSize)
        // Room for the highlighted row's 10 pt bleed into the gutter (the scroll view clips)
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .padding(.horizontal, -10)
    }

    private func nextIsSelected(_ line: UILine) -> Bool {
        guard let sel = selectedID, let i = lines.firstIndex(where: { $0.id == line.id }), i + 1 < lines.count else {
            return false
        }
        return lines[i + 1].id == sel
    }
}

/// One finished line: time · HỌ/BẠN · text. Equatable so unrelated changes skip it.
struct TranscriptRow: View, Equatable {
    let line: UILine
    let selected: Bool
    let separator: Bool

    var body: some View {
        TableRow(separator: separator, highlighted: selected) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                MonoCell(HistoryFormatting.time(line.at)).tableColumn(48)
                MonoCell(Copy.t(line.mine ? "live.mine" : "live.theirs"), type: .monoTag,
                         color: line.mine ? DS.Color.blueText : DS.Color.ink)
                    .tableColumn(40)
                VStack(alignment: .leading, spacing: 8) {
                    Text(TranscriptRowText.shown(line))
                        .ds(selected ? DSType.row.with(weight: 700) : .row)
                        .foregroundStyle(line.unclear ? DS.Color.muted : DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if selected {
                        // Room for the actions overlay (kept out of the row so the row stays Equatable)
                        Text(verbatim: " ").ds(.label).hidden()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.t(line.mine ? "bubble.mine" : "bubble.theirs") + ": " + TranscriptRowText.shown(line))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// "Nghe lại · Sửa · Báo dịch sai" under the selected line.
private struct LineActions: View {
    let replay: () -> Void
    let edit: () -> Void
    let report: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(Copy.t("live.replay"), action: replay)
            Button(Copy.t("live.edit"), action: edit)
            Button(Copy.t("live.report"), action: report).foregroundStyle(DS.Color.warnText)
        }
        .ds(.label)
        .foregroundStyle(DS.Color.ink)
        .buttonStyle(.plain)
    }
}

/// The unfinished phrases (italic, muted, "···" for the time). The only rows that read the partials.
private struct PartialRows: View {
    let ui: UIState

    var body: some View {
        if !ui.theirPartial.isEmpty { row(ui.theirPartial, mine: false) }
        if !ui.myPartial.isEmpty { row(ui.myPartial, mine: true) }
    }

    private func row(_ text: String, mine: Bool) -> some View {
        TableRow(separator: false) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                MonoCell(verbatimDots).tableColumn(48)
                MonoCell(Copy.t(mine ? "live.mine" : "live.theirs"), type: .monoTag,
                         color: mine ? DS.Color.blueText : DS.Color.ink)
                    .tableColumn(40)
                Text(text).ds(DSType.row.with(italic: true)).foregroundStyle(DS.Color.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var verbatimDots: String { "\u{00B7}\u{00B7}\u{00B7}" }
}
