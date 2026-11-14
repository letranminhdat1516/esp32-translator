import AppIntents
import SwiftUI

// The Live Activity's lock-screen and Dynamic Island views (canvas AppLockScreen.dc.html). Shared by the widget
// extension and the app (demo mode renders them in-app for snapshots). The extension compiles the design system's
// Tokens.swift and Fonts.swift too (project.yml), so colours and type come from the same tokens as the app.

enum ActivityPalette {
    static let stone = DS.Color.stone
    static let ink = DS.Color.ink
    static let muted = DS.Color.muted
    static let board = DS.Color.board
    /// The lock-screen card's grille is a shade lighter than the app's dial (canvas: #2A2A2E).
    static let dot = DSHex(0x2A2A2E).color
    static let blue = DS.Color.blue
    static let lightBlue = DS.Color.lightBlue
    /// Secondary text on the black Dynamic Island.
    static let islandMuted = DS.Color.tileText
    static let islandIdle = DS.Color.fieldEdge
}

/// The card's type, fixed sizes (a Live Activity has a fixed height budget).
enum ActivityType {
    /// 14/500: the status line.
    static let status = DSType.label
    /// 13/400: their phrase.
    static let theirs = DSType.caption
    /// 17/700, lh 1.3: the translation.
    static let translation = DSType(family: .grotesk, size: 17, weight: 700, lineHeight: 1.3, relativeTo: .headline)
    /// 16/600: the buttons.
    static let button = DSType.button
    /// 14/500: "EN→VI" in the island.
    static let island = DSType.label
    /// 15/700: the translation in the expanded island.
    static let islandTranslation = DSType(family: .grotesk, size: 15, weight: 700, lineHeight: 1.3, relativeTo: .headline)
    /// 14/600: the expanded island's buttons.
    static let islandButton = DSType.buttonSmall
}

private extension View {
    func activityType(_ type: DSType) -> some View {
        font(.ds(type)).tracking(type.trackingPoints).lineSpacing(type.lineSpacing)
    }
}

/// The lock-screen card: status line, mini board with the ring, their phrase and the translation, two buttons.
struct ActivityLockView: View {
    /// The canvas values (in-app preview), or tighter ones that fit the system's 160 pt lock-screen height.
    struct Metrics: Sendable {
        var padding: CGFloat
        var spacing: CGFloat
        var buttonHeight: CGFloat
        var theirsLines: Int
        var translationLines: Int

        static let canvas = Metrics(padding: 16, spacing: 14, buttonHeight: 46, theirsLines: 2, translationLines: 3)
        /// 12 + 18 + 8 + 64 + 8 + 36 + 12 = 158 pt with a two-line translation.
        static let lockScreen = Metrics(padding: 12, spacing: 8, buttonHeight: 36, theirsLines: 1, translationLines: 2)
    }

    let info: TranslatorActivityStatic
    let state: TranslatorActivityState
    var metrics: Metrics = .canvas

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            HStack {
                HStack(spacing: DS.Space.dotGap) {
                    Circle().fill(state.listening ? ActivityPalette.blue : ActivityPalette.muted).frame(width: 8, height: 8)
                    Text(Copy.t("activity.translating", ["language": info.languageName])).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let b = state.boardBattery {
                    Text(Copy.t("activity.board", ["percent": String(b)])).foregroundStyle(ActivityPalette.muted)
                }
            }
            .activityType(ActivityType.status)
            HStack(alignment: .center, spacing: 12) {
                ActivityMiniBoard(size: 54, ringOn: state.listening && state.micOn)
                VStack(alignment: .leading, spacing: 3) {
                    if !state.theirs.isEmpty {
                        Text(state.theirs).activityType(ActivityType.theirs).foregroundStyle(ActivityPalette.muted)
                            .lineLimit(metrics.theirsLines)
                    }
                    if !state.translation.isEmpty {
                        Text(state.translation).activityType(ActivityType.translation)
                            .lineLimit(metrics.translationLines).layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(intent: ToggleBoardMicIntent()) {
                    Text(Copy.t(state.micOn ? "activity.micOff" : "activity.micOn"))
                        .frame(maxWidth: .infinity, minHeight: metrics.buttonHeight)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ActivityPalette.ink, lineWidth: 1))
                }
                Button(intent: StopConversationIntent()) {
                    Text(Copy.t("activity.stop"))
                        .foregroundStyle(ActivityPalette.stone)
                        .frame(maxWidth: .infinity, minHeight: metrics.buttonHeight)
                        .background(ActivityPalette.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .activityType(ActivityType.button)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .foregroundStyle(ActivityPalette.ink)
        .padding(metrics.padding)
    }
}

/// The 54 pt board: dot grille (6 pt pitch) and a 2 pt blue ring.
struct ActivityMiniBoard: View {
    var size: CGFloat
    var ringOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(ActivityPalette.board)
            Canvas { ctx, sz in
                var path = Path()
                var y: CGFloat = 3
                while y < sz.height {
                    var x: CGFloat = 3
                    while x < sz.width {
                        path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        x += 6
                    }
                    y += 6
                }
                ctx.fill(path, with: .color(ActivityPalette.dot))
            }
            .clipShape(Circle())
            if ringOn {
                Circle().strokeBorder(ActivityPalette.blue, lineWidth: 2).padding(2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The compact Dynamic Island's leading side: a blue dot and "EN→VI".
struct ActivityIslandLeading: View {
    let info: TranslatorActivityStatic
    var listening = true

    var body: some View {
        HStack(spacing: DS.Space.dotGap) {
            Circle().fill(listening ? ActivityPalette.lightBlue : ActivityPalette.islandIdle).frame(width: 8, height: 8)
            Text(verbatim: "\(info.shortCode)\u{2192}VI")
        }
        .activityType(ActivityType.island)
        .foregroundStyle(ActivityPalette.stone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.t("activity.island", ["code": info.shortCode]))
    }
}

/// The ring on the trailing side (and the minimal presentation): blue while the board mic listens.
struct ActivityIslandTrailing: View {
    var on = true
    var size: CGFloat = 18

    var body: some View {
        Circle().strokeBorder(on ? ActivityPalette.blue : ActivityPalette.islandIdle, lineWidth: 2)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The expanded Dynamic Island's bottom region: their phrase, the translation and the two buttons.
struct ActivityIslandExpandedBottom: View {
    let state: TranslatorActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if !state.theirs.isEmpty {
                    Text(state.theirs).activityType(ActivityType.theirs).foregroundStyle(ActivityPalette.islandMuted)
                        .lineLimit(1)
                }
                if !state.translation.isEmpty {
                    Text(state.translation).activityType(ActivityType.islandTranslation)
                        .foregroundStyle(ActivityPalette.stone).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button(intent: ToggleBoardMicIntent()) {
                    Text(Copy.t(state.micOn ? "activity.micOff" : "activity.micOn"))
                        .foregroundStyle(ActivityPalette.stone)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ActivityPalette.islandMuted, lineWidth: 1))
                }
                Button(intent: StopConversationIntent()) {
                    Text(Copy.t("activity.stop"))
                        .foregroundStyle(ActivityPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(ActivityPalette.stone, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .activityType(ActivityType.islandButton)
            .lineLimit(1)
        }
    }
}

/// The expanded island's trailing region: board battery and the ring.
struct ActivityIslandExpandedTrailing: View {
    let state: TranslatorActivityState

    var body: some View {
        HStack(spacing: 8) {
            if let b = state.boardBattery {
                Text(Copy.t("activity.board", ["percent": String(b)]))
                    .activityType(ActivityType.island)
                    .foregroundStyle(ActivityPalette.islandMuted)
            }
            ActivityIslandTrailing(on: state.listening && state.micOn)
        }
    }
}
