import SwiftUI

/// A settings tile: dark (board) or outlined; mono kicker, 32/700 value, caption. Padding 14, radius 14, gap 16.
struct Tile: View {
    enum Style: Hashable, Sendable { case dark, outline }

    var style: Style = .dark
    let kicker: String
    let value: String
    let caption: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: 16) {
            Text(kicker).ds(.monoKicker)
                .foregroundStyle(style == .dark ? DS.Color.tileLabel : DS.Color.muted)
            Text(value).ds(DSType.subtitleBig.with(weight: 700)).lineSpacing(0)
                .foregroundStyle(style == .dark ? DS.Color.stone : DS.Color.ink)
            Text(caption).ds(.caption)
                .foregroundStyle(style == .dark ? DS.Color.tileText : DS.Color.muted)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style == .dark ? DS.Color.board : .clear, in: shape)
        .overlay { if style == .outline { shape.strokeBorder(DS.Color.ink, lineWidth: 1) } }
        .accessibilityElement(children: .combine)
    }
}
