import SwiftUI

/// The orange-outlined notice: mono "!" and a 13 pt message (radius 10, padding 12).
struct WarningBox: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "!").ds(DSType.monoCode.with(size: 13)).foregroundStyle(DS.Color.warnText)
                .frame(width: 22, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).ds(DSType.caption).lineSpacing(13 * 0.17)
                    .foregroundStyle(DS.Color.warnDeep)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .ds(.label)
                        .foregroundStyle(DS.Color.warnText)
                        .underline()
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous)
            .strokeBorder(DS.Color.warnBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The small orange-outlined tag ("Chưa có board").
struct WarnTag: View {
    let text: String

    var body: some View {
        Text(text).ds(.label).foregroundStyle(DS.Color.warnText)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(Rectangle().strokeBorder(DS.Color.warnBorder, lineWidth: 1))
    }
}
