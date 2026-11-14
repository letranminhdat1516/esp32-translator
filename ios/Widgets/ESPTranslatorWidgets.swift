import ActivityKit
import SwiftUI
import WidgetKit

// The widget extension: the conversation's Live Activity (lock screen + Dynamic Island). Track D completes it;
// the views live in Sources/Shared so the app can render them for snapshots.

@main
struct ESPTranslatorWidgets: WidgetBundle {
    var body: some Widget {
        TranslatorLiveActivity()
    }
}

struct TranslatorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranslatorActivityAttributes.self) { context in
            ActivityLockView(info: context.attributes.info, state: context.state)
                .activityBackgroundTint(ActivityPalette.stone)
                .activitySystemActionForegroundColor(ActivityPalette.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ActivityIslandLeading(info: context.attributes.info) }
                DynamicIslandExpandedRegion(.trailing) { ActivityIslandTrailing() }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.theirs).font(ActivityPalette.grotesk(13, .regular)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.state.translation).font(ActivityPalette.grotesk(16, .bold)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                ActivityIslandLeading(info: context.attributes.info)
            } compactTrailing: {
                ActivityIslandTrailing()
            } minimal: {
                ActivityIslandTrailing()
            }
        }
    }
}
