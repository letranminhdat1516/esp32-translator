import SwiftUI

/// The 14/500 top line of every screen: leading and trailing content, space between.
struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .ds(.label)
        .foregroundStyle(DS.Color.ink)
    }
}

/// "← Quay lại": a 44 pt high text link.
struct BackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).ds(.label).foregroundStyle(DS.Color.ink)
                .frame(minHeight: DS.Size.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A 22 pt square checkbox (ink fill with a stone tick, or a 1.5 pt outline).
struct InstrumentCheckbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.checkbox, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(DS.Color.ink)
                Path { p in
                    p.move(to: CGPoint(x: 5.5, y: 11)); p.addLine(to: CGPoint(x: 9.2, y: 14.7)); p.addLine(to: CGPoint(x: 16.5, y: 7.5))
                }
                .stroke(DS.Color.stone, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            } else {
                shape.strokeBorder(DS.Color.ink, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// The "VI | EN ▾" language segment of the Live screen.
struct LanguageSegment: View {
    let home: String
    let other: String

    var body: some View {
        HStack(spacing: 0) {
            Text(home).padding(.horizontal, 9).padding(.vertical, 6)
                .background(DS.Color.ink).foregroundStyle(DS.Color.stone)
            Text(other + " \u{25BE}").padding(.horizontal, 9).padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(DS.Color.ink, lineWidth: 1))
                .foregroundStyle(DS.Color.ink)
        }
        .ds(.monoSegment)
        .frame(minHeight: DS.Size.minTarget)
    }
}
