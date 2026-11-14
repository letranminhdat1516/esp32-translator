import SwiftUI

// "Nhạc cụ" design tokens: every value is copied from the canvas (docs/ui-redesign/canvas/*.dc.html, 390×844).
// Pure values; no app logic. The widget extension keeps its own copy of the few colours it needs.

/// A colour as 0xRRGGBB, kept as an integer so values are testable and comparable.
struct DSHex: Hashable, Sendable, CustomStringConvertible {
    let rgb: UInt32

    init(_ rgb: UInt32) { self.rgb = rgb & 0xFF_FFFF }

    /// "#EBE8E2", "EBE8E2" or "#ebe8e2"; nil for anything else.
    init?(string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(v)
    }

    var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    var blue: Double { Double(rgb & 0xFF) / 255 }

    /// WCAG relative luminance (0 black … 1 white).
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio between two colours (1…21).
    static func contrast(_ a: DSHex, _ b: DSHex) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }

    var description: String { String(format: "#%06X", rgb) }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

enum DS {
    /// Colour values (hex), the single source for `DS.Color`.
    enum Hex {
        static let stone = DSHex(0xEBE8E2)        // screen ground
        static let ink = DSHex(0x141414)          // text, rules, primary buttons
        static let muted = DSHex(0x5D5A55)        // secondary text
        static let rule = DSHex(0xCFCAC1)         // row separators
        static let bezel = DSHex(0xDEDAD3)        // dial bezel ring (10 pt)
        static let bezelEdge = DSHex(0xC9C4BB)    // dial outer edge (1 pt)
        static let board = DSHex(0x0D0D0E)        // the board face, dark tiles
        static let dot = DSHex(0x26262A)          // dot grille on the board
        static let dotDim = DSHex(0x202024)       // dot grille on the phone-only face
        static let blue = DSHex(0x1E6FD9)         // the board's accent, level ring
        static let lightBlue = DSHex(0x4C8FE8)    // dots and knobs on dark
        static let blueText = DSHex(0x1A5DB8)     // "BẠN" label, links
        static let warnText = DSHex(0x8A3F0C)     // destructive / warning text
        static let warnBorder = DSHex(0xA34E12)   // destructive outline
        static let warnDot = DSHex(0xD9761E)      // lost-connection dot and ring
        static let warnDeep = DSHex(0x6E330A)     // warning box body text
        static let highlight = DSHex(0xE0DCD5)    // selected transcript row
        static let boardLabel = DSHex(0x8E8C88)   // small labels on the board face
        static let boardFaint = DSHex(0x6E6C68)   // "…" on the lost board
        static let tileLabel = DSHex(0x9A9893)    // kicker on dark tiles
        static let tileText = DSHex(0xC9C6C0)     // caption on dark tiles
        static let field = DSHex(0x1A1A1C)        // text field on dark
        static let fieldEdge = DSHex(0x3A3A3E)    // idle text field outline on dark
        static let disabledEdge = DSHex(0xA8A39A) // dashed outline of a disabled button
        static let white = DSHex(0xFFFFFF)
        static let lockGround = DSHex(0x1A1918)   // lock screen wallpaper in the snapshot
        static let lockDate = DSHex(0xB9B5AE)
    }

    enum Color {
        static let stone = Hex.stone.color
        static let ink = Hex.ink.color
        static let muted = Hex.muted.color
        static let rule = Hex.rule.color
        static let bezel = Hex.bezel.color
        static let bezelEdge = Hex.bezelEdge.color
        static let board = Hex.board.color
        static let dot = Hex.dot.color
        static let dotDim = Hex.dotDim.color
        static let blue = Hex.blue.color
        static let lightBlue = Hex.lightBlue.color
        static let blueText = Hex.blueText.color
        static let warnText = Hex.warnText.color
        static let warnBorder = Hex.warnBorder.color
        static let warnDot = Hex.warnDot.color
        static let warnDeep = Hex.warnDeep.color
        static let highlight = Hex.highlight.color
        static let boardLabel = Hex.boardLabel.color
        static let boardFaint = Hex.boardFaint.color
        static let tileLabel = Hex.tileLabel.color
        static let tileText = Hex.tileText.color
        static let field = Hex.field.color
        static let fieldEdge = Hex.fieldEdge.color
        static let disabledEdge = Hex.disabledEdge.color
        static let white = Hex.white.color
        static let lockGround = Hex.lockGround.color
        static let lockDate = Hex.lockDate.color
    }

    /// Spacing (pt) as used by the canvas.
    enum Space {
        /// Left/right screen padding.
        static let gutter: CGFloat = 22
        /// Gap between stacked buttons and grid columns.
        static let buttonGap: CGFloat = 10
        /// Vertical padding of a table row.
        static let rowPad: CGFloat = 11
        /// Column gap inside table rows.
        static let column: CGFloat = 8
        /// Gap between a status dot and its label.
        static let dotGap: CGFloat = 6
        /// Bottom padding above the home indicator (canvas: 30 of 844; iOS adds the safe area).
        static let bottom: CGFloat = 8
    }

    enum Radius {
        static let button: CGFloat = 14
        static let smallButton: CGFloat = 10
        static let chipButton: CGFloat = 8
        static let tile: CGFloat = 14
        static let highlight: CGFloat = 8
        static let field: CGFloat = 8
        static let toggle: CGFloat = 6
        static let knob: CGFloat = 4
        static let checkbox: CGFloat = 4
        static let activity: CGFloat = 24
    }

    enum Size {
        /// Primary button height (60 in most screens, 56 in phone-only).
        static let button: CGFloat = 60
        static let buttonCompact: CGFloat = 56
        /// Secondary/destructive lower button.
        static let buttonLow: CGFloat = 48
        static let dial: CGFloat = 250
        static let bezel: CGFloat = 10
        static let bezelEdge: CGFloat = 1
        static let dotPitch: CGFloat = 9
        static let dotRadius: CGFloat = 1.2
        static let statusDot: CGFloat = 8
        static let toggleWidth: CGFloat = 52
        static let toggleHeight: CGFloat = 28
        static let knob: CGFloat = 22
        static let stepWidth: CGFloat = 28
        static let stepHeight: CGFloat = 6
        static let settingsRow: CGFloat = 54
        static let minTarget: CGFloat = 44
    }
}
