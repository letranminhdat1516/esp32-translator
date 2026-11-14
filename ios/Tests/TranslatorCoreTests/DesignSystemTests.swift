import CoreText
import Foundation
import Testing
@testable import TranslatorCore

@Suite struct DesignSystemTests {
    @Test func canvasColoursAreExact() {
        #expect(DS.Hex.stone.rgb == 0xEBE8E2)
        #expect(DS.Hex.ink.rgb == 0x141414)
        #expect(DS.Hex.muted.rgb == 0x5D5A55)
        #expect(DS.Hex.rule.rgb == 0xCFCAC1)
        #expect(DS.Hex.bezel.rgb == 0xDEDAD3)
        #expect(DS.Hex.bezelEdge.rgb == 0xC9C4BB)
        #expect(DS.Hex.board.rgb == 0x0D0D0E)
        #expect(DS.Hex.dot.rgb == 0x26262A)
        #expect(DS.Hex.blue.rgb == 0x1E6FD9)
        #expect(DS.Hex.lightBlue.rgb == 0x4C8FE8)
        #expect(DS.Hex.blueText.rgb == 0x1A5DB8)
        #expect(DS.Hex.warnText.rgb == 0x8A3F0C)
        #expect(DS.Hex.warnBorder.rgb == 0xA34E12)
        #expect(DS.Hex.warnDot.rgb == 0xD9761E)
        #expect(DS.Hex.highlight.rgb == 0xE0DCD5)
    }

    @Test func hexParsing() {
        #expect(DSHex(string: "#EBE8E2") == DS.Hex.stone)
        #expect(DSHex(string: "ebe8e2") == DS.Hex.stone)
        #expect(DSHex(string: " #141414 ") == DS.Hex.ink)
        #expect(DSHex(string: "#12345") == nil)
        #expect(DSHex(string: "#GGGGGG") == nil)
        #expect(DS.Hex.blue.description == "#1E6FD9")
        #expect(abs(DS.Hex.stone.red - 0xEB / 255.0) < 1e-9)
    }

    /// Body text on the stone ground stays readable (WCAG AA 4.5:1), as do the warning and link colours.
    @Test func textContrastOnStone() {
        for c in [DS.Hex.ink, DS.Hex.muted, DS.Hex.blueText, DS.Hex.warnText] {
            #expect(DSHex.contrast(c, DS.Hex.stone) >= 4.5, "\(c)")
        }
        #expect(DSHex.contrast(DS.Hex.stone, DS.Hex.ink) >= 7)
        #expect(DSHex.contrast(DS.Hex.white, DS.Hex.board) >= 7)
        #expect(abs(DSHex.contrast(DS.Hex.white, DSHex(0)) - 21) < 0.01)
    }

    @Test func levelRingFollowsTheLevel() {
        #expect(LevelRing.width(0) == LevelRing.minWidth)
        #expect(LevelRing.width(1) == LevelRing.maxWidth)
        #expect(LevelRing.opacity(0) == LevelRing.minOpacity)
        #expect(abs(LevelRing.opacity(1) - 0.95) < 1e-9)
        #expect(LevelRing.width(0.5) > LevelRing.width(0.25))
        #expect(LevelRing.width(-3) == LevelRing.minWidth)
        #expect(LevelRing.width(7) == LevelRing.maxWidth)
        #expect(LevelRing.opacity(.nan) == LevelRing.minOpacity)
        #expect(LevelRing.clamped(.infinity) == 0)
    }

    @Test func stepProgress() {
        let p = StepProgress(step: 2)
        #expect(p.total == 3)
        #expect([0, 1, 2].map(p.isFilled) == [true, true, false])
        #expect(StepProgress(step: 9).step == 3)
        #expect(StepProgress(step: 0).step == 1)
        #expect(StepProgress(step: 1, total: 0).total == 1)
    }

    @Test func progressRuleClamps() {
        #expect(ProgressRule.clamped(0.64) == 0.64)
        #expect(ProgressRule.clamped(-1) == 0)
        #expect(ProgressRule.clamped(2) == 1)
        #expect(ProgressRule.clamped(.nan) == 0)
    }

    @Test func typeScaleMatchesTheCanvas() {
        #expect(DSType.display.size == 44 && DSType.display.weight == 700)
        #expect(DSType.title.size == 40)
        #expect(DSType.button.size == 16 && DSType.button.weight == 600 && DSType.button.family == .grotesk)
        #expect(DSType.monoTime.family == .mono && DSType.monoTime.size == 11)
        #expect(abs(DSType.display.trackingPoints - (-1.32)) < 1e-9)
        // CSS line-height 1.45 at 16 pt: 23.2 pt lines, the font's own ~20.5
        #expect(abs(DSType.lead.lineSpacing - 2.72) < 0.01)
        #expect(DSType.display.lineSpacing == 0)
        #expect(DSType.button.lineSpacing == 0)
        #expect(DSType(family: .grotesk, size: 10, weight: 900).axisWeight == 700)
        #expect(DSType(family: .mono, size: 10, weight: 50).axisWeight == 100)
        #expect(DSType.row.with(weight: 700).weight == 700)
        #expect(DSType.row.with(italic: true).italic)
    }

    /// The bundled variable fonts carry a weight axis that renders 400/500/600/700 as distinct weights.
    @Test func bundledFontsRenderEveryWeight() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Resources/Fonts")
        for file in ["SpaceGrotesk.ttf", "JetBrainsMono.ttf"] {
            let url = dir.appendingPathComponent(file)
            #expect(FileManager.default.fileExists(atPath: url.path))
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        for family in DSFamily.allCases {
            #expect(DSFonts.isRegistered(family), "\(family)")
            let weights = [400.0, 500, 600, 700].map { DSFonts.resolvedWeight(family, $0) }
            #expect(weights == [400, 500, 600, 700], "\(family): \(weights)")
        }
    }
}
