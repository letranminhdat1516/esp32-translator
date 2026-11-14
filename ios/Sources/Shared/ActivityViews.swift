import AppIntents
import SwiftUI

// The Live Activity's lock-screen and Dynamic Island views. Shared by the widget extension and the app (demo mode
// renders them in-app for snapshots). Colours are copied from DS (the extension does not link the design system).

enum ActivityPalette {
    static let stone = Color(red: 0xEB / 255, green: 0xE8 / 255, blue: 0xE2 / 255)
    static let ink = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
    static let muted = Color(red: 0x5D / 255, green: 0x5A / 255, blue: 0x55 / 255)
    static let board = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0E / 255)
    static let dot = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255)
    static let blue = Color(red: 0x1E / 255, green: 0x6F / 255, blue: 0xD9 / 255)
    static let lightBlue = Color(red: 0x4C / 255, green: 0x8F / 255, blue: 0xE8 / 255)

    static func grotesk(_ size: CGFloat, _ weight: Font.Weight) -> Font { .custom("Space Grotesk", fixedSize: size).weight(weight) }
}

/// The lock-screen card: status line, mini board with the ring, their phrase and the translation, two buttons.
struct ActivityLockView: View {
    let info: TranslatorActivityStatic
    let state: TranslatorActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(state.listening ? ActivityPalette.blue : ActivityPalette.muted).frame(width: 8, height: 8)
                    Text(Copy.t("activity.translating", ["language": info.languageName]))
                }
                Spacer()
                if let b = state.boardBattery {
                    Text(Copy.t("activity.board", ["percent": String(b)])).foregroundStyle(ActivityPalette.muted)
                }
            }
            .font(ActivityPalette.grotesk(14, .medium))
            HStack(alignment: .center, spacing: 12) {
                ActivityMiniBoard(size: 54, ringOn: state.listening && state.micOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.theirs).font(ActivityPalette.grotesk(13, .regular)).foregroundStyle(ActivityPalette.muted)
                        .lineLimit(2)
                    Text(state.translation).font(ActivityPalette.grotesk(17, .bold)).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(intent: ToggleBoardMicIntent()) {
                    Text(Copy.t(state.micOn ? "activity.micOff" : "activity.micOn"))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ActivityPalette.ink, lineWidth: 1))
                }
                Button(intent: StopConversationIntent()) {
                    Text(Copy.t("activity.stop"))
                        .foregroundStyle(ActivityPalette.stone)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(ActivityPalette.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .font(ActivityPalette.grotesk(16, .semibold))
        }
        .foregroundStyle(ActivityPalette.ink)
        .padding(16)
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

/// The compact Dynamic Island: "EN→VI" with a blue dot on the leading side, a ring on the trailing side.
struct ActivityIslandLeading: View {
    let info: TranslatorActivityStatic

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ActivityPalette.lightBlue).frame(width: 8, height: 8)
            Text(verbatim: "\(info.languageCode.uppercased())\u{2192}VI")
        }
        .font(ActivityPalette.grotesk(14, .medium))
        .foregroundStyle(ActivityPalette.stone)
    }
}

struct ActivityIslandTrailing: View {
    var body: some View {
        Circle().strokeBorder(ActivityPalette.blue, lineWidth: 2).frame(width: 18, height: 18)
    }
}
