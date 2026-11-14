import SwiftUI

/// The screen frame of the canvas: stone ground, ink text, 22 pt gutters, content from the top safe area to the
/// bottom safe area (canvas: 60 pt top including the status bar, 30 pt bottom).
struct InstrumentScreen<Content: View>: View {
    var bottomPadding: CGFloat = DS.Space.bottom
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(DS.Color.ink)
            .background(DS.Color.stone.ignoresSafeArea())
    }
}
