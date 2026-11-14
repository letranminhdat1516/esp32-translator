import CoreText
import SwiftUI

// Space Grotesk for the UI, JetBrains Mono for times, percentages and codes. Both are variable fonts bundled in
// Resources/Fonts and registered by the app's Info.plist (`UIAppFonts`), so nothing runs on the first frame.
// The weight is set on the variation axis ('wght'): Space Grotesk's named instances don't include 600.

enum DSFamily: String, Sendable, CaseIterable {
    case grotesk = "Space Grotesk"
    case mono = "JetBrains Mono"

    /// The weight axis range of the bundled variable font.
    var weightRange: ClosedRange<Double> {
        switch self {
        case .grotesk: 300...700
        case .mono: 100...800
        }
    }
}

/// One entry of the type scale. Sizes are the canvas px at the default Dynamic Type size.
struct DSType: Hashable, Sendable {
    var family: DSFamily
    var size: CGFloat
    var weight: Double
    /// Letter spacing in em (CSS `letter-spacing`).
    var tracking: CGFloat = 0
    /// CSS `line-height` multiple; nil = the font's natural height.
    var lineHeight: CGFloat?
    /// The Dynamic Type style it scales with.
    var relativeTo: Font.TextStyle = .body
    var italic = false

    /// Kerning in points for `.tracking(_:)`.
    var trackingPoints: CGFloat { tracking * size }

    /// Extra space between lines for `.lineSpacing(_:)`: CSS line height minus the font's own (≈1.28 em for both
    /// families), never negative.
    var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        return max(0, (lineHeight - 1.28) * size)
    }

    /// The weight clamped to the font's axis.
    var axisWeight: Double { min(max(weight, family.weightRange.lowerBound), family.weightRange.upperBound) }

    func with(size: CGFloat? = nil, weight: Double? = nil, italic: Bool? = nil) -> DSType {
        var t = self
        if let size { t.size = size }
        if let weight { t.weight = weight }
        if let italic { t.italic = italic }
        return t
    }
}

extension DSType {
    // Space Grotesk
    /// 44/700, −0.03em, lh 1 ("Cấp quyền", "Cài đặt").
    static let display = DSType(family: .grotesk, size: 44, weight: 700, tracking: -0.03, lineHeight: 1, relativeTo: .largeTitle)
    /// 40/700, −0.03em, lh 1.02 ("Dịch hội thoại hai chiều", "Ghép board").
    static let title = DSType(family: .grotesk, size: 40, weight: 700, tracking: -0.03, lineHeight: 1.02, relativeTo: .largeTitle)
    /// 36/700 ("Mất kết nối board").
    static let title2 = DSType(family: .grotesk, size: 36, weight: 700, tracking: -0.03, lineHeight: 1.02, relativeTo: .title)
    /// 32/700, −0.02em: the phone-only subtitle and tile values.
    static let subtitleBig = DSType(family: .grotesk, size: 32, weight: 700, tracking: -0.02, lineHeight: 1.15, relativeTo: .title)
    /// 26/700, −0.02em: "Họ nói" text in phone-only.
    static let heard = DSType(family: .grotesk, size: 26, weight: 700, tracking: -0.02, lineHeight: 1.18, relativeTo: .title2)
    /// 19/500 white: the live subtitle on the dial.
    static let dial = DSType(family: .grotesk, size: 19, weight: 500, lineHeight: 1.25, relativeTo: .title3)
    /// 17/700: list item title ("Micro", "English", "Bến Thành").
    static let rowTitle = DSType(family: .grotesk, size: 17, weight: 700, relativeTo: .headline)
    /// 17/400: unselected language name.
    static let rowName = DSType(family: .grotesk, size: 17, weight: 400, relativeTo: .body)
    /// 16/400, lh 1.45: lead paragraph.
    static let lead = DSType(family: .grotesk, size: 16, weight: 400, lineHeight: 1.45, relativeTo: .body)
    /// 16/400: settings row label.
    static let body = DSType(family: .grotesk, size: 16, weight: 400, relativeTo: .body)
    /// 16/700: history row title, board name.
    static let bodyBold = DSType(family: .grotesk, size: 16, weight: 700, relativeTo: .headline)
    /// 15/400, lh 1.45: paragraph under a title.
    static let paragraph = DSType(family: .grotesk, size: 15, weight: 400, lineHeight: 1.45, relativeTo: .body)
    /// 15/400, lh 1.35: transcript and table rows.
    static let row = DSType(family: .grotesk, size: 15, weight: 400, lineHeight: 1.35, relativeTo: .body)
    /// 14/500: top bar, section header, inline links.
    static let label = DSType(family: .grotesk, size: 14, weight: 500, relativeTo: .subheadline)
    /// 14/400, lh 1.45: short paragraph.
    static let small = DSType(family: .grotesk, size: 14, weight: 400, lineHeight: 1.45, relativeTo: .subheadline)
    /// 13/400: captions and notes.
    static let caption = DSType(family: .grotesk, size: 13, weight: 400, relativeTo: .footnote)
    /// 16/600: every button.
    static let button = DSType(family: .grotesk, size: 16, weight: 600, relativeTo: .body)
    /// 14/600: compact buttons ("Tải · 310 MB").
    static let buttonSmall = DSType(family: .grotesk, size: 14, weight: 600, relativeTo: .subheadline)

    // JetBrains Mono
    /// 11/400: times ("14:20").
    static let monoTime = DSType(family: .mono, size: 11, weight: 400, relativeTo: .caption)
    /// 11/700: speaker codes ("HỌ", "BẠN"), table keys.
    static let monoTag = DSType(family: .mono, size: 11, weight: 700, relativeTo: .caption)
    /// 11/400, lh 1.6, 0.04em: footnote ("Nếu không có AirPods…").
    static let monoNote = DSType(family: .mono, size: 11, weight: 400, tracking: 0.04, lineHeight: 1.6, relativeTo: .caption)
    /// 11/500, 0.08em: the language segment ("VI | EN ▾").
    static let monoSegment = DSType(family: .mono, size: 11, weight: 500, tracking: 0.08, relativeTo: .caption)
    /// 12/700: language codes ("EN") and settings values.
    static let monoCode = DSType(family: .mono, size: 12, weight: 700, relativeTo: .caption)
    /// 12/400: settings values ("Tắt", "6 từ").
    static let monoValue = DSType(family: .mono, size: 12, weight: 400, relativeTo: .caption)
    /// 10/400, 0.12em: tile kicker ("Board").
    static let monoKicker = DSType(family: .mono, size: 10, weight: 400, tracking: 0.12, relativeTo: .caption2)
    /// 46/700, 0.06em: pairing code on the dial.
    static let monoCodeBig = DSType(family: .mono, size: 46, weight: 700, tracking: 0.06, relativeTo: .largeTitle)
    /// 30/700: "…" on the lost dial.
    static let monoEllipsis = DSType(family: .mono, size: 30, weight: 700, relativeTo: .title)
}

/// Builds and caches the CoreText fonts (one per family, weight and size).
enum DSFonts {
    private static let wghtAxis = 0x7767_6874 // 'wght'
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]
    private static let lock = NSLock()

    /// `italic`: both families ship upright only, so the slant is synthesized (12° shear).
    static func ctFont(_ family: DSFamily, weight: Double, size: CGFloat, italic: Bool = false) -> CTFont {
        let key = "\(family.rawValue)|\(weight)|\(size)|\(italic)"
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family.rawValue,
            kCTFontVariationAttribute: [wghtAxis: weight],
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        let font = italic ? CTFontCreateWithFontDescriptor(desc, size, &shear) : CTFontCreateWithFontDescriptor(desc, size, nil)
        cache[key] = font
        return font
    }

    static func font(_ type: DSType, size: CGFloat? = nil) -> Font {
        Font(ctFont(type.family, weight: type.axisWeight, size: size ?? type.size, italic: type.italic))
    }

    /// True when the bundled family is registered (the family name resolves to itself, not a fallback).
    static func isRegistered(_ family: DSFamily) -> Bool {
        let name = CTFontCopyFamilyName(ctFont(family, weight: 400, size: 12)) as String
        return name == family.rawValue
    }

    /// The weight the resolved font actually carries for a requested weight (0 when the axis is missing): lets
    /// demo mode and tests check that 400/500/600/700 render as distinct weights.
    static func resolvedWeight(_ family: DSFamily, _ weight: Double) -> Double {
        let font = ctFont(family, weight: weight, size: 12)
        let vars = (CTFontCopyVariation(font) as? [NSNumber: NSNumber]) ?? [:]
        if let v = vars[NSNumber(value: wghtAxis)] { return v.doubleValue }
        // At the axis default CoreText leaves the axis out of the variation: report the default
        let axes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == wghtAxis }
        return (axis?[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? 0
    }
}

extension Font {
    /// A fixed-size font of the scale (no Dynamic Type): for the board face and the widget.
    static func ds(_ type: DSType) -> Font { DSFonts.font(type) }
}

/// Applies a type-scale entry: font, tracking and line spacing; body text scales with Dynamic Type, mono labels are
/// capped at `.accessibility1`.
private struct DSTypeModifier: ViewModifier {
    let type: DSType
    @ScaledMetric private var size: CGFloat

    init(type: DSType, scales: Bool) {
        self.type = type
        _size = ScaledMetric(wrappedValue: type.size, relativeTo: type.relativeTo)
        self.scales = scales
    }

    private let scales: Bool

    func body(content: Content) -> some View {
        let s = scales ? size : type.size
        let ratio = s / type.size
        content
            .font(DSFonts.font(type, size: s))
            .tracking(type.trackingPoints * ratio)
            .lineSpacing(type.lineSpacing * ratio)
            .dynamicTypeSize(type.family == .mono ? DynamicTypeSize.xSmall ... .accessibility1
                                                  : DynamicTypeSize.xSmall ... .accessibility5)
    }
}

extension View {
    /// Text in the given style; `scales: false` for text on the board face, where the dial has a fixed size.
    func ds(_ type: DSType, scales: Bool = true) -> some View {
        modifier(DSTypeModifier(type: type, scales: scales))
    }
}
