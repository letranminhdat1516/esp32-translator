import Foundation
import Testing
@testable import TranslatorCore

struct ConversationActivityTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func startsIdle() {
        var activity = ConversationActivity()
        #expect(activity.state == .idle)
        #expect(activity.handle(.tick, at: at(1000)) == nil)
        #expect(activity.handle(.gateClosed, at: at(1)) == nil)
        #expect(activity.handle(.ttsEnd, at: at(1)) == nil)
        #expect(activity.handle(.stop, at: at(1)) == nil)
        #expect(activity.state == .idle)
    }

    @Test(arguments: [ConversationActivity.Event.boardAudio, .gateOpen, .ttsStart, .userStart])
    func speechOrTapStartsAConversation(_ event: ConversationActivity.Event) {
        var activity = ConversationActivity()
        #expect(activity.handle(event, at: at(0)) == .start)
        #expect(activity.state == .active)
        // Already active: no second start
        #expect(activity.handle(event, at: at(1)) == nil)
    }

    @Test func endsAfterTenMinutesOfSilence() {
        var activity = ConversationActivity()
        #expect(activity.idleTimeout == 600)
        #expect(activity.handle(.boardAudio, at: at(0)) == .start)
        #expect(activity.handle(.tick, at: at(599)) == nil)
        #expect(activity.handle(.tick, at: at(600)) == .stop)
        #expect(activity.state == .idle)
        #expect(activity.handle(.tick, at: at(1500)) == nil)
    }

    @Test func boardAudioKeepsItAlive() {
        var activity = ConversationActivity()
        _ = activity.handle(.userStart, at: at(0))
        _ = activity.handle(.boardAudio, at: at(100))
        #expect(activity.handle(.tick, at: at(650)) == nil)
        #expect(activity.handle(.tick, at: at(700)) == .stop)
    }

    @Test func openGateNeverTimesOut() {
        var activity = ConversationActivity()
        _ = activity.handle(.gateOpen, at: at(0))
        #expect(activity.handle(.tick, at: at(1000)) == nil)
        // The timeout counts from when the wearer stopped
        _ = activity.handle(.gateClosed, at: at(1000))
        #expect(activity.handle(.tick, at: at(1599)) == nil)
        #expect(activity.handle(.tick, at: at(1600)) == .stop)
    }

    @Test func speakingNeverTimesOut() {
        var activity = ConversationActivity()
        #expect(activity.handle(.ttsStart, at: at(0)) == .start)
        #expect(activity.handle(.tick, at: at(1000)) == nil)
        _ = activity.handle(.ttsEnd, at: at(1010))
        #expect(activity.handle(.tick, at: at(1609)) == nil)
        #expect(activity.handle(.tick, at: at(1610)) == .stop)
    }

    @Test func stopEndsRightAwayAndClearsFlags() {
        var activity = ConversationActivity()
        _ = activity.handle(.gateOpen, at: at(0))
        _ = activity.handle(.ttsStart, at: at(0))
        #expect(activity.handle(.stop, at: at(1)) == .stop)
        #expect(activity.state == .idle)
        // A new conversation is not held open by the old gate / speech flags
        #expect(activity.handle(.userStart, at: at(10)) == .start)
        #expect(activity.handle(.tick, at: at(610)) == .stop)
    }

    @Test func endEventsWhileIdleDoNotStartOrStretch() {
        var activity = ConversationActivity()
        _ = activity.handle(.userStart, at: at(0))
        #expect(activity.handle(.tick, at: at(600)) == .stop)
        #expect(activity.handle(.gateClosed, at: at(610)) == nil)
        #expect(activity.handle(.ttsEnd, at: at(610)) == nil)
        #expect(activity.state == .idle)
    }

    @Test func customTimeout() {
        var activity = ConversationActivity(idleTimeout: 5)
        _ = activity.handle(.userStart, at: at(0))
        #expect(activity.handle(.tick, at: at(4.9)) == nil)
        #expect(activity.handle(.tick, at: at(5)) == .stop)
    }

    @Test func failedStartGoesBackToIdleWithoutStop() {
        var activity = ConversationActivity()
        _ = activity.handle(.gateOpen, at: at(0))
        #expect(activity.handle(.ttsStart, at: at(0)) == nil)
        activity.startFailed(at: at(0))
        #expect(activity.state == .idle)
        #expect(!activity.isActive)
        // Nothing to release: ticks and stops don't report a transition
        #expect(activity.handle(.tick, at: at(5)) == nil)
        #expect(activity.handle(.stop, at: at(5)) == nil)
    }

    @Test(arguments: [ConversationActivity.Event.boardAudio, .gateOpen, .ttsStart])
    func failedStartHoldsOffAutomaticRetries(_ event: ConversationActivity.Event) {
        var activity = ConversationActivity(retryDelay: 30)
        #expect(activity.handle(.boardAudio, at: at(0)) == .start)
        activity.startFailed(at: at(0))
        #expect(activity.handle(event, at: at(1)) == nil)
        #expect(activity.handle(event, at: at(29.9)) == nil)
        #expect(activity.state == .idle)
        #expect(activity.handle(event, at: at(30)) == .start)
    }

    @Test func tapRetriesRightAfterAFailedStart() {
        var activity = ConversationActivity()
        #expect(activity.handle(.boardAudio, at: at(0)) == .start)
        activity.startFailed(at: at(0))
        #expect(activity.handle(.userStart, at: at(1)) == .start)
        // A tap clears the hold-off: after another success + end, board audio restarts at once
        #expect(activity.handle(.stop, at: at(2)) == .stop)
        #expect(activity.handle(.boardAudio, at: at(3)) == .start)
    }

    @Test func flagsFromAFailedStartDoNotHoldTheNextConversation() {
        var activity = ConversationActivity(retryDelay: 0)
        _ = activity.handle(.gateOpen, at: at(0))
        _ = activity.handle(.ttsStart, at: at(0))
        activity.startFailed(at: at(0))
        #expect(activity.handle(.userStart, at: at(10)) == .start)
        #expect(activity.handle(.tick, at: at(610)) == .stop)
    }

    @Test func stopTapEndsItUntilTheNextTap() {
        var activity = ConversationActivity()
        #expect(activity.handle(.userStart, at: at(0)) == .start)
        #expect(activity.handle(.gateOpen, at: at(1)) == nil)
        #expect(activity.handle(.userStop, at: at(2)) == .stop)
        #expect(activity.state == .idle)
        // Board audio and translations don't take the mic back, even much later
        #expect(activity.handle(.boardAudio, at: at(3)) == nil)
        #expect(activity.handle(.ttsStart, at: at(10_000)) == nil)
        #expect(activity.state == .idle)
        #expect(activity.handle(.userStart, at: at(10_001)) == .start)
    }

    @Test func stopTapWhileIdleDoesNothing() {
        var activity = ConversationActivity()
        #expect(activity.handle(.userStop, at: at(0)) == nil)
        #expect(activity.handle(.userStart, at: at(1)) == .start)
    }
}
