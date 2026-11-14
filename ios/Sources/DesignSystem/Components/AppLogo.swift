import SwiftUI

/// The Live Translator mark from the canvas (SVG viewBox 10 10 80 80): two arrows around a flame.
struct AppLogo: View {
    var size: CGFloat = 96

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 80
            ctx.translateBy(x: -10 * s, y: -10 * s)
            ctx.scaleBy(x: s, y: s)
            let arrow = Self.arrow()
            ctx.fill(arrow, with: .color(DS.Color.blue))
            ctx.fill(arrow.applying(CGAffineTransform(translationX: 100, y: 100).rotated(by: .pi)),
                     with: .color(DS.Color.stone))
            ctx.fill(Self.flame(), with: .color(DS.Color.lightBlue))
        }
        .frame(width: size, height: size)
    }

    /// The upper arrow: an arc band (r 34 → 20 around 50,50) with an arrowhead on the right.
    static func arrow() -> Path {
        var p = Path()
        let c = CGPoint(x: 50, y: 50)
        p.move(to: CGPoint(x: 16.52, y: 44.10))
        p.addArc(center: c, radius: 34, startAngle: .degrees(190), endAngle: .degrees(340), clockwise: false)
        p.addLine(to: CGPoint(x: 85.71, y: 37.00))
        p.addLine(to: CGPoint(x: 76.98, y: 50.94))
        p.addLine(to: CGPoint(x: 65.04, y: 44.53))
        p.addLine(to: CGPoint(x: 68.79, y: 43.16))
        p.addArc(center: c, radius: 20, startAngle: .degrees(340), endAngle: .degrees(190), clockwise: true)
        p.closeSubpath()
        return p
    }

    static func flame() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 50, y: 37))
        p.addCurve(to: CGPoint(x: 60, y: 55), control1: CGPoint(x: 56, y: 44), control2: CGPoint(x: 60, y: 49))
        p.addArc(center: CGPoint(x: 50, y: 55), radius: 10, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: CGPoint(x: 46, y: 43), control1: CGPoint(x: 40, y: 50), control2: CGPoint(x: 44, y: 47))
        p.addCurve(to: CGPoint(x: 50, y: 49), control1: CGPoint(x: 47, y: 47), control2: CGPoint(x: 48, y: 48))
        p.addCurve(to: CGPoint(x: 50, y: 37), control1: CGPoint(x: 50, y: 45), control2: CGPoint(x: 49, y: 41))
        p.closeSubpath()
        return p
    }
}
