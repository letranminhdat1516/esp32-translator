import SwiftUI

/// A section label above a ruled list ("Hôm nay", "Câu bạn đã báo sai (3)"): 14/500.
struct SectionHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).ds(.label).foregroundStyle(DS.Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The large screen title (44/700 by default).
struct ScreenTitle: View {
    let text: String
    var type: DSType = .display

    init(_ text: String, type: DSType = .display) {
        self.text = text
        self.type = type
    }

    var body: some View {
        Text(text).ds(type).foregroundStyle(DS.Color.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
