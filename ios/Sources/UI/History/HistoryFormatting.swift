import Foundation

/// Groups and labels history sessions for the list ("Hôm nay", "Hôm qua", "Thứ Năm, 13/11"). Pure, tested.
enum HistoryFormatting {
    struct Section: Hashable, Sendable {
        var title: String
        var sessions: [HistorySession]
    }

    static func vietnamese(_ calendar: Calendar) -> Calendar {
        var c = calendar
        c.locale = Locale(identifier: "vi_VN")
        return c
    }

    /// Newest day first, newest session first inside a day.
    static func sections(_ sessions: [HistorySession], now: Date, calendar: Calendar = .current) -> [Section] {
        let byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { day in
            Section(title: dayTitle(day, now: now, calendar: calendar),
                    sessions: byDay[day, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return Copy.t("history.today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) {
            return Copy.t("history.yesterday")
        }
        let c = calendar.dateComponents([.weekday, .day, .month], from: day)
        return Copy.t("history.day", ["weekday": weekday(c.weekday ?? 1), "day": String(c.day ?? 0),
                                       "month": String(c.month ?? 0)])
    }

    /// "Chủ Nhật", "Thứ Hai" … "Thứ Bảy" (Calendar weekday 1 = Sunday).
    static func weekday(_ n: Int) -> String {
        let keys = ["weekday.1", "weekday.2", "weekday.3", "weekday.4", "weekday.5", "weekday.6", "weekday.7"]
        return Copy.t(keys[min(max(n, 1), 7) - 1])
    }

    /// "14:20" (24-hour, the canvas' mono times).
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "Thứ Bảy, 15 tháng 11" (the lock screen date).
    static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        return Copy.t("lock.date", ["weekday": weekday(c.weekday ?? 1), "day": String(c.day ?? 0),
                                     "month": String(c.month ?? 0)])
    }

    /// Whole seconds between `then` and `now`, never negative ("12 giây trước").
    static func secondsAgo(_ then: Date, now: Date) -> Int { max(0, Int(now.timeIntervalSince(then))) }
}
