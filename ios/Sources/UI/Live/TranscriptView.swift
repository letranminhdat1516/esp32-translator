import SwiftUI

/// Both sides in one ruled stream, oldest first, in Vietnamese (their translation, your own words). A tapped line
/// opens its actions; partials are a separate leaf so they never re-render the finished rows.
struct TranscriptView: View {
    let lines: [UILine]
    /// The partial phrases: only `PartialRows` reads them, so a partial re-renders that row alone.
    let partials: PartialModel
    @Binding var selectedID: String?
    var onReplay: (UILine) -> Void = { _ in }
    /// The corrected translation for a line ("Sửa").
    var onEdit: (UILine, String) -> Void = { _, _ in }
    var onReport: (UILine) -> Void = { _ in }

    /// The line being corrected inline, and its draft.
    @State private var editingID: String?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    if line.id == editingID {
                        EditingRow(line: line, draft: $draft, save: { save(line) }, cancel: { editingID = nil })
                    } else {
                        row(line)
                    }
                }
                PartialRows(partials: partials)
            }
            .padding(.top, 1)
            .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
        }
        // Short transcripts sit under the dial; long ones open scrolled to the newest line
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        // Room for the highlighted row's 10 pt bleed into the gutter (the scroll view clips)
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .padding(.horizontal, -10)
    }

    private func row(_ line: UILine) -> some View {
        TranscriptRow(line: line, selected: line.id == selectedID,
                      separator: !(line.id == selectedID || nextIsSelected(line)))
            .equatable()
            .contentShape(Rectangle())
            .onTapGesture { selectedID = selectedID == line.id ? nil : line.id }
            .overlay(alignment: .bottomLeading) {
                if line.id == selectedID {
                    LineActions(replay: { onReplay(line) }, edit: { startEditing(line) }, report: {
                        onReport(line)
                        selectedID = nil
                    })
                    .padding(.leading, 48 + 40 + 2 * DS.Space.column)
                    .padding(.bottom, DS.Space.rowPad)
                }
            }
    }

    private func startEditing(_ line: UILine) {
        draft = LineEditText.initial(line)
        editingID = line.id
    }

    private func save(_ line: UILine) {
        onEdit(line, draft)
        editingID = nil
        selectedID = nil
    }

    private func nextIsSelected(_ line: UILine) -> Bool {
        guard let sel = selectedID, let i = lines.firstIndex(where: { $0.id == line.id }), i + 1 < lines.count else {
            return false
        }
        return lines[i + 1].id == sel
    }
}

/// "Sửa" in place: the translation in a field, Lưu · Huỷ.
private struct EditingRow: View {
    let line: UILine
    @Binding var draft: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TableRow(separator: false, highlighted: true) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                MonoCell(HistoryFormatting.time(line.at)).tableColumn(48)
                MonoCell(Copy.t(line.mine ? "live.mine" : "live.theirs"), type: .monoTag,
                         color: line.mine ? DS.Color.blueText : DS.Color.ink)
                    .tableColumn(40)
                VStack(alignment: .leading, spacing: 8) {
                    TextField(Copy.t("live.editField"), text: $draft, axis: .vertical)
                        .ds(DSType.row.with(weight: 700))
                        .foregroundStyle(DS.Color.ink)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityLabel(Copy.t("live.editField"))
                    if line.mine {
                        Text(line.source).ds(.small).foregroundStyle(DS.Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button(Copy.t("live.save"), action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(Copy.t("live.cancel"), action: cancel).foregroundStyle(DS.Color.muted)
                    }
                    .ds(.label)
                    .foregroundStyle(DS.Color.ink)
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { focused = true }
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

    /// Extra room around each label so its hit target is at least 44 pt; taken back from the layout so the labels
    /// sit where they did.
    private static let vPad: CGFloat = 14
    private static let hPad: CGFloat = 6

    var body: some View {
        HStack(spacing: 12 - 2 * Self.hPad) {
            action(Copy.t("live.replay"), replay)
            action(Copy.t("live.edit"), edit)
            action(Copy.t("live.report"), report).foregroundStyle(DS.Color.warnText)
        }
        .padding(.vertical, -Self.vPad)
        .padding(.horizontal, -Self.hPad)
        .ds(.label)
        .foregroundStyle(DS.Color.ink)
        .buttonStyle(.plain)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .padding(.vertical, Self.vPad)
                .padding(.horizontal, Self.hPad)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

/// The unfinished phrases (italic, muted, "···" for the time). The only rows that read the partials.
private struct PartialRows: View {
    let partials: PartialModel

    var body: some View {
        if !partials.theirs.isEmpty { row(partials.theirs, mine: false) }
        if !partials.mine.isEmpty { row(partials.mine, mine: true) }
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
