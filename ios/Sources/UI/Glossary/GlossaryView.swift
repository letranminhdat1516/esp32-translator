import SwiftUI

// 3.3 Từ riêng: terms that are kept as they are when translating. The view holds no list of its own: after a
// closure returns, the controller has updated `ui.glossaryTerms`. Validation messages come from the store.

struct GlossaryView: View {
    var ui: UIState
    let router: AppRouter
    @State private var addText: String
    @State private var fixedText = ""
    @State private var addError: String?
    @State private var editText = ""
    @State private var editError: String?
    /// A refused delete: shown on the row, not under the add field
    @State private var rowError: (id: String, message: String)?
    @State private var editingId: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case add, fixed, edit }

    init(ui: UIState, router: AppRouter, draft: String = "") {
        self.ui = ui
        self.router = router
        _addText = State(initialValue: draft)
    }

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                Text(Copy.t("glossary.count", ["count": String(ui.glossaryTerms.count)])).foregroundStyle(DS.Color.muted)
            }
            ScreenTitle(Copy.t("glossary.screenTitle")).padding(.top, 6)
            Text(Copy.t("glossary.intro")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            addCard.padding(.top, 18)
            ScrollView {
                if ui.glossaryTerms.isEmpty {
                    Text(Copy.t("glossary.empty")).ds(.small).foregroundStyle(DS.Color.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                } else {
                    RuledList {
                        ForEach(ui.glossaryTerms, id: \.id) { term in
                            if term.id == editingId { editRow(term) } else { row(term) }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 18)
        }
    }

    // MARK: Add

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            darkField(Copy.t("glossary.addLabel"), text: $addText, field: .add, prompt: Copy.t("glossary.addHint"),
                      error: addError ?? ui.glossaryError)
                .onSubmit(add)
                .onChange(of: addText) { addError = nil }
            darkField(Copy.t("glossary.fixedLabel"), text: $fixedText, field: .fixed, prompt: Copy.t("glossary.fixedHint"),
                      error: nil)
                .onSubmit(add)
            Button(Copy.t("glossary.add"), action: add)
                .buttonStyle(InstrumentButtonStyle(kind: .inverse, height: 46, radius: DS.Radius.smallButton))
        }
        .padding(14)
        .background(DS.Color.board, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
    }

    private func darkField(_ label: String, text: Binding<String>, field: Field, prompt: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).ds(.caption).foregroundStyle(DS.Color.tileLabel)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(DS.Color.muted))
                .ds(text.wrappedValue.isEmpty ? DSType.body : DSType.body.with(weight: 500))
                .foregroundStyle(DS.Color.white)
                .modifier(PlainTextInput())
                .submitLabel(.done)
                .focused($focus, equals: field)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(DS.Color.field, in: RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(focus == field || !text.wrappedValue.isEmpty ? DS.Color.lightBlue : DS.Color.fieldEdge, lineWidth: 1))
                .accessibilityLabel(label)
            if let error {
                Text(error).ds(.caption).foregroundStyle(DS.Color.warnDot)
                    .accessibilityLabel(Copy.t("glossary.errorLabel", ["error": error]))
            }
        }
    }

    // MARK: Rows

    private func fixedTranslation(_ term: Term) -> String {
        if let code = ui.languageCode, let f = term.fixed[code], !f.isEmpty { return f }
        return Copy.t("glossary.keep")
    }

    private func row(_ term: Term) -> some View {
        TableRow(verticalPadding: 13) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.column) {
                    Text(term.text).ds(.rowTitle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(fixedTranslation(term)).ds(.caption).foregroundStyle(DS.Color.muted)
                }
                if let e = rowError, e.id == term.id {
                    Text(e.message).ds(.caption).foregroundStyle(DS.Color.warnText)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if term.origin == .user {
                Button(Copy.t("glossary.edit", ["term": term.text])) {
                    editingId = term.id
                    editError = nil
                    editText = term.text
                    focus = .edit
                }
                Button(Copy.t("glossary.delete", ["term": term.text]), role: .destructive) { delete(term.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func editRow(_ term: Term) -> some View {
        TableRow(verticalPadding: 10) {
            VStack(alignment: .trailing, spacing: 8) {
                TextField("", text: $editText)
                    .ds(.body)
                    .modifier(PlainTextInput())
                    .focused($focus, equals: .edit)
                    .onSubmit { save(term.id) }
                    .onChange(of: editText) { editError = nil }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).strokeBorder(DS.Color.ink, lineWidth: 1))
                    .accessibilityLabel(Copy.t("glossary.editLabel"))
                if let editError {
                    Text(editError).ds(.caption).foregroundStyle(DS.Color.warnText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 16) {
                    Button(Copy.t("glossary.cancel")) {
                        editingId = nil
                        editError = nil
                    }
                    Button(Copy.t("glossary.save")) { save(term.id) }.fontWeight(.semibold)
                }
                .ds(.label)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func message(_ error: Error) -> String {
        (error as? GlossaryValidationError)?.message ?? Copy.t("glossary.saveFailed")
    }

    private func add() {
        do {
            let fixed = fixedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let addFixed = ui.glossaryAddFixed, !fixed.isEmpty {
                try addFixed(addText, fixed)
            } else {
                try ui.glossaryAdd(addText)
            }
            addText = ""
            fixedText = ""
            addError = nil
        } catch {
            addError = message(error)
        }
    }

    private func save(_ id: String) {
        do {
            try ui.glossaryUpdate(id, editText)
            editingId = nil
            editError = nil
        } catch {
            editError = message(error)
        }
    }

    private func delete(_ id: String) {
        do {
            try ui.glossaryDelete(id)
            rowError = nil
        } catch {
            rowError = (id, message(error))
        }
    }
}

/// No capitalisation or autocorrect for terms.
private struct PlainTextInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}
