import SwiftUI

/// An 8 pt round dot with an optional label ("Đang nghe", "Đã cho phép", "Mất kết nối").
struct StatusDot: View {
    var color: Color = DS.Color.blue
    var label: String?
    var labelColor: Color = DS.Color.ink
    var type: DSType = .label

    var body: some View {
        HStack(spacing: DS.Space.dotGap) {
            Circle().fill(color).frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                .accessibilityHidden(true)
            if let label { Text(label).ds(type).foregroundStyle(labelColor) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An 8 pt ink square: the bullet of the welcome list.
struct SquareBullet: View {
    var body: some View {
        Rectangle().fill(DS.Color.ink).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}
