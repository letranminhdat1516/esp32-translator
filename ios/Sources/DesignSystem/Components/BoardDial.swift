import Observation
import SwiftUI

/// Anything that publishes a voice level 0…1 (the app's throttled `LevelModel`). Only the ring's leaf view reads
/// it, so a level change redraws the ring and nothing else.
@MainActor
protocol LevelSource: AnyObject, Observable {
    var level: Double { get }
}

/// A fixed level, for previews, demo mode and the static arcs.
@Observable @MainActor
final class FixedLevel: LevelSource {
    var level: Double
    init(_ level: Double) { self.level = level }
}

/// How the level ring maps a level to a stroke. Pure, tested.
enum LevelRing {
    /// Width at silence and at full voice (canvas: the ring is ~4.8 pt at full).
    static let minWidth: CGFloat = 1.5
    static let maxWidth: CGFloat = 5
    /// Opacity at silence and at full voice (canvas: rgba(30,111,217,0.95)).
    static let minOpacity = 0.25
    static let maxOpacity = 0.95

    static func clamped(_ level: Double) -> Double {
        level.isFinite ? min(max(level, 0), 1) : 0
    }

    static func width(_ level: Double) -> CGFloat {
        minWidth + (maxWidth - minWidth) * CGFloat(clamped(level))
    }

    static func opacity(_ level: Double) -> Double {
        minOpacity + (maxOpacity - minOpacity) * clamped(level)
    }
}

/// The tint of the dial's ring.
enum DialTint: Hashable, Sendable {
    case blue, warn

    var color: Color { self == .blue ? DS.Color.blue : DS.Color.warnDot }
}

/// What the ring around the board face shows.
enum DialRing {
    case none
    /// A static arc. Angles as in CSS conic-gradient: 0° at 12 o'clock, clockwise.
    case arc(fromDegrees: Double, sweepDegrees: Double, tint: DialTint, inset: CGFloat = 5)
    /// A full ring whose width and opacity follow a live level.
    case level(any LevelSource, tint: DialTint, inset: CGFloat = 5)
}

/// The board object: black face with a dot grille, a 10 pt bezel and a 1 pt edge (outside the layout size, like
/// the canvas' box-shadow), a ring, and centre content.
struct BoardDial<Content: View>: View {
    var size: CGFloat = DS.Size.dial
    var ring: DialRing = .none
    var dimmed = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            DotGrille(dot: DS.Color.dot)
                .clipShape(Circle())
            ringView
            content()
        }
        .frame(width: size, height: size)
        .background(Circle().fill(DS.Color.board))
        .background(
            Circle()
                .fill(DS.Color.bezel)
                .padding(-DS.Size.bezel)
                .background(Circle().fill(DS.Color.bezelEdge).padding(-(DS.Size.bezel + DS.Size.bezelEdge)))
        )
        .opacity(dimmed ? 0.92 : 1)
    }

    @ViewBuilder
    private var ringView: some View {
        switch ring {
        case .none:
            EmptyView()
        case let .arc(from, sweep, tint, inset):
            ArcRing(fromDegrees: from, sweepDegrees: sweep, color: tint.color)
                .padding(inset)
                .accessibilityHidden(true)
        case let .level(source, tint, inset):
            LevelRingView(source: source, color: tint.color)
                .padding(inset)
                .accessibilityHidden(true)
        }
    }
}

/// The dot grille: 1.2 pt dots on a 9 pt pitch, drawn once into one GPU layer.
struct DotGrille: View {
    var dot: Color
    var pitch: CGFloat = DS.Size.dotPitch
    var radius: CGFloat = DS.Size.dotRadius

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            var path = Path()
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += pitch
                }
                y += pitch
            }
            ctx.fill(path, with: .color(dot))
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A static arc, ~4.8 pt wide (the canvas mask: 96–100 % of the radius).
private struct ArcRing: View {
    let fromDegrees: Double
    let sweepDegrees: Double
    let color: Color

    var body: some View {
        Circle()
            .inset(by: LevelRing.maxWidth / 2)
            .trim(from: 0, to: min(max(sweepDegrees / 360, 0), 1))
            .stroke(color, style: StrokeStyle(lineWidth: LevelRing.maxWidth, lineCap: .butt))
            // SwiftUI's 0° is at 3 o'clock, CSS conic-gradient's at 12
            .rotationEffect(.degrees(fromDegrees - 90))
    }
}

/// The only view that reads the level: a Canvas stroke whose width and opacity follow it.
private struct LevelRingView: View {
    let source: any LevelSource
    let color: Color

    var body: some View {
        let level = source.level
        Canvas { ctx, size in
            let w = LevelRing.width(level)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: LevelRing.maxWidth - w / 2, dy: LevelRing.maxWidth - w / 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(LevelRing.opacity(level))), lineWidth: w)
        }
        .allowsHitTesting(false)
    }
}

#Preview("Dials") {
    VStack(spacing: 40) {
        BoardDial(ring: .arc(fromDegrees: 200, sweepDegrees: 140, tint: .blue, inset: 6)) { Color.clear }
        BoardDial(ring: .level(FixedLevel(0.8), tint: .blue)) { Color.clear }
    }
    .padding(40)
    .background(DS.Color.stone)
}
