import SwiftUI

/// The canvas' stroke icons (24-unit SVG viewBox, 1.6 stroke, round caps), as shapes.
enum DSIcon: Hashable, Sendable {
    case list, sliders, mic, bluetooth, waveform, search, play

    var filled: Bool { self == .play }
}

struct DSIconShape: Shape {
    let icon: DSIcon

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
            path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1))
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: rect.minX + (cx - r) * s, y: rect.minY + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        switch icon {
        case .list:
            line((4, 6), (20, 6)); line((4, 12), (20, 12)); line((4, 18), (14, 18))
        case .sliders:
            line((4, 7), (14, 7)); line((18, 7), (20, 7)); line((4, 17), (6, 17)); line((10, 17), (20, 17))
            circle(16, 7, 2); circle(8, 17, 2)
        case .mic:
            path.addRoundedRect(in: CGRect(x: rect.minX + 9 * s, y: rect.minY + 3 * s, width: 6 * s, height: 11 * s),
                                cornerSize: CGSize(width: 3 * s, height: 3 * s))
            path.move(to: p(5, 11))
            path.addArc(center: p(12, 11), radius: 7 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            line((12, 18), (12, 21))
        case .bluetooth:
            path.move(to: p(7, 7)); path.addLine(to: p(17, 17)); path.addLine(to: p(12, 22)); path.addLine(to: p(12, 2))
            path.addLine(to: p(17, 7)); path.addLine(to: p(7, 17))
        case .waveform:
            line((3, 12), (5, 12)); line((7, 8), (7, 16)); line((11, 5), (11, 19)); line((15, 9), (15, 15)); line((19, 11), (19, 13))
        case .search:
            circle(11, 11, 7); line((20, 20), (16.5, 16.5))
        case .play:
            path.move(to: p(7, 5)); path.addLine(to: p(19, 12)); path.addLine(to: p(7, 19)); path.closeSubpath()
        }
        return path
    }
}

/// An icon at a given size in a given colour.
struct DSIconView: View {
    let icon: DSIcon
    var size: CGFloat = 22
    var color: Color = DS.Color.ink
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Group {
            if icon.filled {
                DSIconShape(icon: icon).fill(color)
            } else {
                DSIconShape(icon: icon)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 24, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
