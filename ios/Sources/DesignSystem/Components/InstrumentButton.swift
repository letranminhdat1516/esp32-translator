import SwiftUI

/// The button kinds of the canvas: an ink block, a 1 pt ink outline, an orange outline, and a stone block on dark
/// surfaces ("Thêm" on the glossary card).
enum InstrumentButtonKind: Hashable, Sendable {
    case primary, secondary, destructive, inverse
}

/// Space Grotesk 600 16, radius 14, full width. Height 60 (primary), 48 (lower secondary), 56 (phone-only).
struct InstrumentButtonStyle: ButtonStyle {
    var kind: InstrumentButtonKind = .primary
    var height: CGFloat = DS.Size.button
    var radius: CGFloat = DS.Radius.button
    var type: DSType = .button
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .ds(type, scales: false)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(foreground)
            .padding(.horizontal, fullWidth ? 12 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(background, in: shape)
            .overlay { border(shape) }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return DS.Color.muted }
        switch kind {
        case .primary: return DS.Color.stone
        case .secondary, .inverse: return DS.Color.ink
        case .destructive: return DS.Color.warnText
        }
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        switch kind {
        case .primary: return DS.Color.ink
        case .inverse: return DS.Color.stone
        case .secondary, .destructive: return .clear
        }
    }

    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if !isEnabled {
            // The canvas' disabled "Tiếp tục": dashed #A8A39A outline, muted text
            shape.strokeBorder(DS.Color.disabledEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            switch kind {
            case .primary, .inverse: EmptyView()
            case .secondary: shape.strokeBorder(DS.Color.ink, lineWidth: 1)
            case .destructive: shape.strokeBorder(DS.Color.warnBorder, lineWidth: 1)
            }
        }
    }
}

/// A full-width instrument button with a text title.
struct InstrumentButton: View {
    let title: String
    var kind: InstrumentButtonKind = .primary
    var height: CGFloat = DS.Size.button
    let action: () -> Void

    init(_ title: String, kind: InstrumentButtonKind = .primary, height: CGFloat = DS.Size.button,
         action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(InstrumentButtonStyle(kind: kind, height: height))
    }
}

/// A square icon button with a 1 pt ink outline (Live's "Lịch sử" and "Cài đặt", 60×60).
struct InstrumentIconButton<Icon: View>: View {
    let label: String
    var size: CGFloat = DS.Size.button
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 22, height: 22)
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .strokeBorder(DS.Color.ink, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension ButtonStyle where Self == InstrumentButtonStyle {
    static func instrument(_ kind: InstrumentButtonKind = .primary, height: CGFloat = DS.Size.button) -> InstrumentButtonStyle {
        InstrumentButtonStyle(kind: kind, height: height)
    }

    /// The compact buttons inside rows ("Cho phép" 40 pt radius 10, "Tải · 310 MB" 36 pt radius 8).
    static func instrumentCompact(_ kind: InstrumentButtonKind = .secondary, height: CGFloat = 40,
                                  radius: CGFloat = DS.Radius.smallButton, type: DSType = .button) -> InstrumentButtonStyle {
        InstrumentButtonStyle(kind: kind, height: height, radius: radius, type: type, fullWidth: false)
    }
}
