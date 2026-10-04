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

    @Test func endsAfterTwoMinutesOfSilence() {
        var activity = ConversationActivity()
        #expect(activity.handle(.boardAudio, at: at(0)) == .start)
        #expect(activity.handle(.tick, at: at(119)) == nil)
        #expect(activity.handle(.tick, at: at(120)) == .stop)
        #expect(activity.state == .idle)
        #expect(activity.handle(.tick, at: at(500)) == nil)
    }

    @Test func boardAudioKeepsItAlive() {
        var activity = ConversationActivity()
        _ = activity.handle(.userStart, at: at(0))
        _ = activity.handle(.boardAudio, at: at(100))
        #expect(activity.handle(.tick, at: at(200)) == nil)
        #expect(activity.handle(.tick, at: at(220)) == .stop)
    }

    @Test func openGateNeverTimesOut() {
        var activity = ConversationActivity()
        _ = activity.handle(.gateOpen, at: at(0))
        #expect(activity.handle(.tick, at: at(300)) == nil)
        // The timeout counts from when the wearer stopped
        _ = activity.handle(.gateClosed, at: at(300))
        #expect(activity.handle(.tick, at: at(419)) == nil)
        #expect(activity.handle(.tick, at: at(420)) == .stop)
    }

    @Test func speakingNeverTimesOut() {
        var activity = ConversationActivity()
        #expect(activity.handle(.ttsStart, at: at(0)) == .start)
        #expect(activity.handle(.tick, at: at(300)) == nil)
        _ = activity.handle(.ttsEnd, at: at(310))
        #expect(activity.handle(.tick, at: at(429)) == nil)
        #expect(activity.handle(.tick, at: at(430)) == .stop)
    }

    @Test func stopEndsRightAwayAndClearsFlags() {
        var activity = ConversationActivity()
        _ = activity.handle(.gateOpen, at: at(0))
        _ = activity.handle(.ttsStart, at: at(0))
        #expect(activity.handle(.stop, at: at(1)) == .stop)
        #expect(activity.state == .idle)
        // A new conversation is not held open by the old gate / speech flags
        #expect(activity.handle(.userStart, at: at(10)) == .start)
        #expect(activity.handle(.tick, at: at(130)) == .stop)
    }

    @Test func endEventsWhileIdleDoNotStartOrStretch() {
        var activity = ConversationActivity()
        _ = activity.handle(.userStart, at: at(0))
        #expect(activity.handle(.tick, at: at(120)) == .stop)
        #expect(activity.handle(.gateClosed, at: at(130)) == nil)
        #expect(activity.handle(.ttsEnd, at: at(130)) == nil)
        #expect(activity.state == .idle)
    }

    @Test func customTimeout() {
        var activity = ConversationActivity(idleTimeout: 5)
        _ = activity.handle(.userStart, at: at(0))
        #expect(activity.handle(.tick, at: at(4.9)) == nil)
        #expect(activity.handle(.tick, at: at(5)) == .stop)
    }
}
