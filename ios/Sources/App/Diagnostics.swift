import Foundation
import os

/// Lightweight diagnostics: timestamped lines on stdout (visible with `devicectl ... launch --console`)
/// plus per-second counters for each pipeline stage.
enum Diag {
    private static let start: Date = {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so the console shows events as they happen
        return Date()
    }()
    private static let lock = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func log(_ message: @autoclosure () -> String) {
        let t = Date().timeIntervalSince(start)
        print(String(format: "[%8.2f] ", t) + message())
    }

    static func count(_ key: String, _ n: Int = 1) {
        lock.withLock { $0[key, default: 0] += n }
    }

    /// Returns and resets the counters
    static func drain() -> [String: Int] {
        lock.withLock { counters in
            defer { counters.removeAll() }
            return counters
        }
    }
}
