import Foundation
import Testing
@testable import ClaudeBoardCore

func hookEvent(_ name: String, sid: String = "s1", cwd: String = "/x/alpha", extra: String = "") -> HookEvent {
    try! HookEvent.parse(Data(#"{"hook_event_name":"\#(name)","session_id":"\#(sid)","cwd":"\#(cwd)"\#(extra)}"#.utf8))
}

@Test func createsOnFirstEventAndFocusesTheFirstSession() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 100)
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta"), now: 110)
    let rows = t.rows()
    #expect(rows.map(\.project) == ["beta", "alpha"])          // most recent first
    #expect(rows.first { $0.project == "alpha" }?.focused == true)
    #expect(rows.first { $0.project == "beta" }?.focused == false)
    #expect(t.focusedId == "s1")
    #expect(rows.map(\.handle).sorted() == [1, 2])
}

@Test func statesFollowTheHooks() {
    var t = SessionTracker(sessionHooks: true)
    func state() -> SessionState? { t.rows().first?.state }
    t.record(hookEvent("SessionStart"), now: 1);                                         #expect(state() == .idle)
    t.record(hookEvent("UserPromptSubmit"), now: 2);                                     #expect(state() == .working)
    t.record(hookEvent("PermissionRequest", extra: #","tool_name":"Bash""#), now: 3);   #expect(state() == .needsYou)
    t.requestAnswered("s1", now: 4);                                                     #expect(state() == .working)
    t.record(hookEvent("Notification", extra: #","notification_type":"permission_prompt""#), now: 5)
    #expect(state() == .needsYou)
    t.record(hookEvent("Notification", extra: #","notification_type":"auth_success""#), now: 6)
    #expect(state() == .needsYou)
    t.record(hookEvent("Notification", extra: #","notification_type":"idle_prompt""#), now: 7)
    #expect(state() == .idle)
    t.record(hookEvent("Stop", extra: #","last_assistant_message":"All tests pass.\nDone 🎉""#), now: 8)
    #expect(state() == .idle && t.rows().first?.lastLine == "Done 🎉")
    t.record(hookEvent("SessionEnd"), now: 9);                                           #expect(state() == .ended)
    t.record(hookEvent("UserPromptSubmit"), now: 10);                                    #expect(state() == .working)  // resumed
}

@Test func requestAnsweredOnlyLeavesNeedsYou() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("Stop"), now: 1)
    t.requestAnswered("s1", now: 2)
    #expect(t.rows().first?.state == .idle)
    t.requestAnswered("unknown", now: 3)
    #expect(t.rows().count == 1)
}

@Test func sinceChangesOnlyWithTheState() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 100)
    t.record(hookEvent("UserPromptSubmit"), now: 150)
    #expect(t.rows()[0].since == 100 && t.rows()[0].updated == 150)
    t.record(hookEvent("Stop"), now: 200)
    #expect(t.rows()[0].since == 200)
}

@Test func stopOfTheFocusedSessionIsDoneOthersBecomeUnseen() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 1)                                // s1 focused
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta"), now: 2)
    // (mutating calls cannot sit inside #expect: take the result first)
    let focusedDone = t.record(hookEvent("Stop", extra: #","last_assistant_message":"ok""#), now: 3)
    #expect(focusedDone == .focusedDone(project: "alpha", line: "ok"))
    let otherDone = t.record(hookEvent("Stop", sid: "s2", cwd: "/x/beta"), now: 4)
    #expect(otherDone == .none)
    #expect(t.rows().first { $0.project == "beta" }?.unseen == true)
    let beta = t.rows().first { $0.project == "beta" }!.handle
    let focused = t.focus(handle: beta)
    #expect(focused)
    #expect(t.rows().first { $0.project == "beta" }?.unseen == false)
    #expect(t.rows().first { $0.project == "beta" }?.focused == true)
    let unknown = t.focus(handle: 999)
    #expect(!unknown)
}

@Test func markAllSeenClearsEveryBadge() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 1)
    t.record(hookEvent("Stop", sid: "s2"), now: 2)
    t.record(hookEvent("Stop", sid: "s3"), now: 3)
    #expect(t.rows().filter(\.unseen).count == 2)
    t.markAllSeen()
    #expect(t.rows().filter(\.unseen).isEmpty)
}

@Test func rowsPutNeedsYouFirstAndKeepTheFocusedOneWithinSix() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit", sid: "old", cwd: "/x/old"), now: 1)     // focused, oldest
    for i in 0..<7 { t.record(hookEvent("UserPromptSubmit", sid: "s\(i)", cwd: "/x/p\(i)"), now: 10 + Int64(i)) }
    t.record(hookEvent("PermissionRequest", sid: "s0", cwd: "/x/p0"), now: 20)
    let rows = t.rows()
    #expect(rows.count == SessionTracker.visibleMax)
    #expect(rows[0].project == "p0" && rows[0].state == .needsYou)
    #expect(rows.contains { $0.project == "old" && $0.focused })
    #expect(rows.filter { !$0.focused && $0.state != .needsYou }.map(\.updated) == [16, 15, 14, 13])
}

@Test func endedSessionsAreDroppedAfterTenMinutes() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("SessionEnd"), now: 1000)
    t.expire(now: 1000 + 599)
    #expect(t.rows().count == 1)
    t.expire(now: 1000 + 600)
    #expect(t.rows().isEmpty && t.focusedId == nil)
}

@Test func silentSessionsEndAfterTwoHoursWithOrWithoutSessionHooks() {
    // A crashed or killed Claude Code never sends SessionEnd: the 2 h fallback applies with session hooks too
    for hooks in [true, false] {
        var t = SessionTracker(sessionHooks: hooks)
        t.record(hookEvent("Stop"), now: 0)
        t.expire(now: 7199)
        #expect(t.rows().first?.state == .idle)
        t.expire(now: 7200)
        #expect(t.rows().first?.state == .ended && t.rows().first?.since == 7200)
        t.expire(now: 7200 + 600)
        #expect(t.rows().isEmpty && t.focusedId == nil)
    }
}

@Test func aWorkingSessionThatGoesSilentAlsoEnds() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit"), now: 0)
    t.record(hookEvent("PermissionRequest", sid: "s2", extra: #","tool_name":"Bash""#), now: 0)
    t.expire(now: 7200)
    #expect(t.rows().allSatisfy { $0.state == .ended })
}

@Test func droppingTheFocusedSessionRefocusesTheMostRecentlyUpdatedOne() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("SessionEnd"), now: 1000)                                   // s1 focused, ended
    t.record(hookEvent("UserPromptSubmit", sid: "s2", cwd: "/x/beta"), now: 1100)
    t.record(hookEvent("Stop", sid: "s3", cwd: "/x/gamma"), now: 1200)            // unseen, most recent
    t.record(hookEvent("Stop", sid: "s2", cwd: "/x/beta"), now: 1150)
    #expect(t.focusedId == "s1")
    t.expire(now: 1000 + 600)                                                       // s1 dropped
    #expect(t.focusedId == "s3")
    let rows = t.rows()
    #expect(rows.count == 2)
    #expect(rows.first { $0.project == "gamma" }?.focused == true)
    #expect(rows.first { $0.project == "gamma" }?.unseen == false)
    #expect(rows.first { $0.project == "beta" }?.focused == false)
}

@Test func keepsTheTmuxPaneAndIgnoresEventsWithoutSession() {
    var t = SessionTracker(sessionHooks: true)
    t.record(hookEvent("UserPromptSubmit", extra: #","claude_board_tmux_pane":"%4""#), now: 1)
    t.record(hookEvent("Stop"), now: 2)                       // no pane in this event: keep the old one
    #expect(t.tmuxPane(sessionId: "s1") == "%4")
    t.record(hookEvent("Stop", sid: ""), now: 3)
    #expect(t.rows().count == 1)
}

@Test func handlesSkipZero() {
    var t = SessionTracker(sessionHooks: true)
    t.nextHandle = .max
    t.record(hookEvent("Stop", sid: "a"), now: 1)
    t.record(hookEvent("Stop", sid: "b"), now: 2)
    #expect(Set(t.rows().map(\.handle)) == [UInt32.max, 1])
}
