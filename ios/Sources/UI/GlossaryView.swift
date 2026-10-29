import SwiftUI

// Port of app/lib/ui/glossary_screen.dart: "Từ điển riêng", terms that are kept as they are when translating. The
// view holds no list of its own: after a closure returns, the controller has updated `ui.glossaryTerms`.

struct GlossaryView: View {
    var ui: UIState
    @Environment(\.dismiss) private var dismiss
    @State private var addText = ""
    @State private var addError: String?
    @State private var editText = ""
    @State private var editError: String?
    /// A refused delete: shown on the row, not under the add field
    @State private var rowError: (id: String, message: String)?
    @State private var editingId: String?
    @FocusState private var editFocused: Bool

    private static let errorColor = Color(red: 0xE5 / 255, green: 0x64 / 255, blue: 0x5A / 255)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Từ điển riêng").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Xong") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.accentLight)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)
            addRow
            if ui.glossaryTerms.isEmpty {
                Spacer()
                Text("Chưa có từ nào").font(.system(size: 15)).foregroundStyle(Palette.muted)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(ui.glossaryTerms, id: \.id) { term in
                            if term.id == editingId { editRow(term) } else { row(term) }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var addRow: some View {
        HStack(alignment: .top, spacing: 12) {
            field("Thêm từ giữ nguyên", text: $addText, error: addError)
                .onSubmit(add)
                .onChange(of: addText) { addError = nil }
            Button(action: add) {
                Text("Thêm")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func field(_ hint: String, text: Binding<String>, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: text, prompt: Text(hint).foregroundStyle(Palette.faint))
                .accessibilityLabel(hint.isEmpty ? "Sửa từ" : hint)
                .modifier(PlainTextInput())
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Palette.surface, in: Capsule())
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Self.errorColor).padding(.horizontal, 16)
                    .accessibilityLabel("Lỗi: \(error)")
            }
        }
        .padding(.top, 4)
    }

    private func row(_ term: Term) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text).font(.system(size: 17, weight: .semibold))
                if !term.variants.isEmpty {
                    Text(term.variants.joined(separator: ", ")).font(.system(size: 14)).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            if term.origin == .user {
                iconButton("pencil", label: "Sửa \(term.text)") {
                    editingId = term.id
                    editError = nil
                    editText = term.text
                    editFocused = true
                }
                iconButton("trash", label: "Xoá \(term.text)") { delete(term.id) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            if let e = rowError, e.id == term.id {
                Text(e.message).font(.system(size: 12)).foregroundStyle(Self.errorColor).padding(.horizontal, 20)
            }
        }
    }

    private func editRow(_ term: Term) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            field("", text: $editText, error: editError)
                .focused($editFocused)
                .onSubmit { save(term.id) }
                .onChange(of: editText) { editError = nil }
            HStack(spacing: 16) {
                Button("Huỷ") {
                    editingId = nil
                    editError = nil
                }
                Button("Lưu") { save(term.id) }.fontWeight(.semibold)
            }
            .font(.system(size: 16))
            .foregroundStyle(Palette.accentLight)
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18)).foregroundStyle(Palette.muted).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func message(_ error: Error) -> String {
        (error as? GlossaryValidationError)?.message ?? "Không lưu được"
    }

    private func add() {
        do {
            try ui.glossaryAdd(addText)
            addText = ""
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

#if DEBUG
#Preview("Glossary") {
    GlossaryView(ui: .sampleGlossary())
}

#Preview("Glossary, empty") {
    GlossaryView(ui: UIState())
}

#Preview("Glossary, validation error") {
    GlossaryView(ui: .sampleGlossary(rejecting: GlossaryMessages.tooLong), addText: String(repeating: "a", count: 70))
}

extension GlossaryView {
    /// For previews: starts with text typed and the add button already pressed.
    init(ui: UIState, addText: String) {
        self.init(ui: ui)
        _addText = State(initialValue: addText)
        _addError = State(initialValue: GlossaryMessages.tooLong)
    }
}

#endif

/// No capitalisation or autocorrect for terms (iOS only, so the Mac preview still compiles).
private struct PlainTextInput: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}
