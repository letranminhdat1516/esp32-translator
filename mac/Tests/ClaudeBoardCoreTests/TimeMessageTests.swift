import Foundation
import Testing
@testable import ClaudeBoardCore

@Test func encodesTimeAsAsciiWithZeroId() {
    let d = BoardMessage.time(unixSeconds: 1759555200, offsetMinutes: -330).encode()
    #expect(Array(d) == [3, 0, 0, 0, 0] + Array("1759555200 -330".utf8))
}

@Test func timeSyncUsesTheZoneOffsetAtThatInstant() {
    let d = Date(timeIntervalSince1970: 1759555200)   // 2025-10-04 05:20 UTC
    #expect(BoardMessage.timeSync(at: d, in: TimeZone(identifier: "Asia/Ho_Chi_Minh")!)
            == .time(unixSeconds: 1759555200, offsetMinutes: 420))
    #expect(BoardMessage.timeSync(at: d, in: TimeZone(identifier: "America/New_York")!)
            == .time(unixSeconds: 1759555200, offsetMinutes: -240))   // daylight saving time in October
    #expect(BoardMessage.timeSync(at: d, in: TimeZone(identifier: "Asia/Kathmandu")!)
            == .time(unixSeconds: 1759555200, offsetMinutes: 345))
}

@Test func timeSyncDropsFractionalSeconds() {
    let d = Date(timeIntervalSince1970: 1759555200.9)
    #expect(BoardMessage.timeSync(at: d, in: TimeZone(identifier: "UTC")!)
            == .time(unixSeconds: 1759555200, offsetMinutes: 0))
}
