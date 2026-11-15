import SwiftUI

/// A 6 pt bar with a 1 pt ink outline, filled ink up to `fraction` ("Đang tải 64%").
struct ProgressRule: View {
    let fraction: Double
    var height: CGFloat = 6
    /// Fill and outline: ink on stone, stone on the selected (ink) row
    var color: Color = DS.Color.ink

    /// The fill clamped to 0…1 (NaN → 0).
    static func clamped(_ f: Double) -> Double { f.isFinite ? min(max(f, 0), 1) : 0 }

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(color)
                .frame(width: geo.size.width * Self.clamped(fraction))
        }
        .frame(height: height)
        .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((Self.clamped(fraction) * 100).rounded()))%"))
    }
}
