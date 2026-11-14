import SwiftUI

/// A ruled table: a 1 pt ink rule on top, rows separated by 1 pt #CFCAC1 rules.
struct RuledList<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(.top, 1)
            .overlay(alignment: .top) { Rectangle().fill(DS.Color.ink).frame(height: 1) }
    }
}

/// One table row. Lay the columns out with an `HStack` and `.tableColumn(_:)`; `highlighted` is the selected
/// transcript row (#E0DCD5, radius 8, bleeding 10 pt into the gutter, no separator).
struct TableRow<Content: View>: View {
    var verticalPadding: CGFloat = DS.Space.rowPad
    var minHeight: CGFloat?
    var separator = true
    var highlighted = false
    var fill: Color?
    var horizontalBleed: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        let bleed = highlighted || fill != nil ? horizontalBleed : 0
        content()
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, bleed)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background {
                if highlighted || fill != nil {
                    RoundedRectangle(cornerRadius: highlighted ? DS.Radius.highlight : DS.Radius.smallButton, style: .continuous)
                        .fill(fill ?? DS.Color.highlight)
                }
            }
            .padding(.horizontal, -bleed)
            .overlay(alignment: .bottom) {
                if separator && !highlighted && fill == nil { Rectangle().fill(DS.Color.rule).frame(height: 1) }
            }
            .padding(.bottom, separator && !highlighted && fill == nil ? 1 : 0)
    }
}

extension View {
    /// A fixed-width table column (the canvas' grid track).
    func tableColumn(_ width: CGFloat, alignment: Alignment = .leading) -> some View {
        frame(width: width, alignment: alignment)
    }
}

/// A time or code cell in JetBrains Mono.
struct MonoCell: View {
    let text: String
    var type: DSType = .monoTime
    var color: Color = DS.Color.muted

    init(_ text: String, type: DSType = .monoTime, color: Color = DS.Color.muted) {
        self.text = text
        self.type = type
        self.color = color
    }

    var body: some View {
        Text(text).ds(type).foregroundStyle(color).lineLimit(1)
    }
}
