import Foundation

/// One saved conversation (one file `yyyyMMdd-HHmmss-<lang>.json` in Application Support/History).
struct HistorySession: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var startedAt: Date
    var languageCode: String
    var lines: [HistoryLine]
    /// How many lines the session has (the list shows it without loading every line).
    var lineCount: Int

    init(id: String, startedAt: Date, languageCode: String, lines: [HistoryLine] = [], lineCount: Int? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.languageCode = languageCode
        self.lines = lines
        self.lineCount = lineCount ?? lines.count
    }

    /// The first phrase, used as the title in the list.
    var title: String { lines.first.map { $0.mine ? $0.source : $0.target } ?? "" }

    /// The file name: `yyyyMMdd-HHmmss-<lang>.json` (local time).
    static func fileName(startedAt: Date, languageCode: String, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: startedAt)
        return String(format: "%04d%02d%02d-%02d%02d%02d-%@.json", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, languageCode)
    }
}

struct HistoryLine: Hashable, Codable, Sendable {
    var mine: Bool
    var source: String
    var target: String
    var at: Date
}

/// Persists finished lines per session. Track C implements the file store (background actor, batched flush every
/// 2 s and on stop/background, gated by "Lưu lịch sử", excluded from backup).
protocol HistoryStoring: Sendable {
    func sessions() async -> [HistorySession]
    func append(_ line: HistoryLine, sessionID: String, languageCode: String) async
    func delete(sessionID: String) async
    func deleteAll() async
}

/// Keeps sessions in memory: demo mode and tests.
actor InMemoryHistoryStore: HistoryStoring {
    private var store: [String: HistorySession]

    init(_ sessions: [HistorySession] = []) {
        store = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func sessions() async -> [HistorySession] { store.values.sorted { $0.startedAt > $1.startedAt } }

    func append(_ line: HistoryLine, sessionID: String, languageCode: String) async {
        var s = store[sessionID] ?? HistorySession(id: sessionID, startedAt: line.at, languageCode: languageCode)
        s.lines.append(line)
        s.lineCount = s.lines.count
        store[sessionID] = s
    }

    func delete(sessionID: String) async { store[sessionID] = nil }
    func deleteAll() async { store.removeAll() }
}
