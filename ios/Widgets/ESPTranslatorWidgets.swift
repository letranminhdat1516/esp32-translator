import ActivityKit
import CoreText
import SwiftUI
import WidgetKit

// The widget extension: the conversation's Live Activity (lock screen + Dynamic Island). The views live in
// Sources/Shared so the app can render them for snapshots; the buttons' intents run in the app process.

@main
struct ESPTranslatorWidgets: WidgetBundle {
    init() {
        ActivityFonts.registerIfNeeded()
    }

    var body: some Widget {
        TranslatorLiveActivity()
    }
}

struct TranslatorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranslatorActivityAttributes.self) { context in
            ActivityLockView(info: context.attributes.info, state: context.state, metrics: .lockScreen)
                .activityBackgroundTint(ActivityPalette.stone)
                .activitySystemActionForegroundColor(ActivityPalette.ink)
        } dynamicIsland: { context in
            let info = context.attributes.info
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityIslandLeading(info: info, listening: state.listening)
                        .padding(.leading, 6)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityIslandExpandedTrailing(state: state)
                        .padding(.trailing, 6)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityIslandExpandedBottom(state: state)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ActivityIslandLeading(info: info, listening: state.listening)
            } compactTrailing: {
                ActivityIslandTrailing(on: state.listening && state.micOn)
            } minimal: {
                ActivityIslandTrailing(on: state.listening && state.micOn)
            }
            .keylineTint(ActivityPalette.blue)
        }
    }
}

/// `UIAppFonts` in the extension's Info.plist registers the fonts; registering them from the bundle as well makes
/// sure the card never falls back to the system font (a second registration just fails, harmlessly). No check
/// through `DSFonts` first: it caches the fonts it resolves, a fallback included.
enum ActivityFonts {
    static func registerIfNeeded() {
        for name in ["SpaceGrotesk", "JetBrainsMono"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
