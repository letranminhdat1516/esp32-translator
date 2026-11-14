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
    var title: String { lines.first.map { $0.mine ? $0.source : ($0.target.isEmpty ? $0.source : $0.target) } ?? "" }

    /// The file name: `yyyyMMdd-HHmmss-<lang>.json` (local time).
    static func fileName(startedAt: Date, languageCode: String, calendar: Calendar = .current) -> String {
        "\(id(startedAt: startedAt, languageCode: languageCode, calendar: calendar)).json"
    }

    /// The session id: its file name without `.json`.
    static func id(startedAt: Date, languageCode: String, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: startedAt)
        return String(format: "%04d%02d%02d-%02d%02d%02d-%@", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, languageCode)
    }

    /// Case-insensitive match on any phrase of the session (the list's search).
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q)
            || lines.contains { $0.source.localizedCaseInsensitiveContains(q) || $0.target.localizedCaseInsensitiveContains(q) }
    }

    /// The transcript as plain text (detail → share).
    var transcript: String {
        lines.map { l in
            let shown = l.mine ? l.source : (l.target.isEmpty ? l.source : l.target)
            let other = l.mine ? l.target : l.source
            return other.isEmpty || other == shown ? shown : "\(shown)\n  \(other)"
        }
        .joined(separator: "\n")
    }
}

struct HistoryLine: Hashable, Codable, Sendable {
    var mine: Bool
    var source: String
    var target: String
    var at: Date
    /// The transcript line's id (`UILine.id`): a later version of the same line replaces it. nil: always appended.
    var id: String? = nil
}

/// Persists finished lines per session.
protocol HistoryStoring: Sendable {
    func sessions() async -> [HistorySession]
    /// Adds `line` to the session (created on its first line); a line with the id of one already there replaces it.
    func append(_ line: HistoryLine, sessionID: String, languageCode: String) async
    func delete(sessionID: String) async
    func deleteAll() async
    /// "Lưu lịch sử": while off, `append` drops lines.
    func setEnabled(_ on: Bool) async
    /// Writes what is pending now (stop, background).
    func flush() async
}

extension HistoryStoring {
    func setEnabled(_ on: Bool) async {}
    func flush() async {}
}

extension HistorySession {
    /// Upserts `line` by id (see `HistoryStoring.append`).
    mutating func upsert(_ line: HistoryLine) {
        if let id = line.id, let i = lines.lastIndex(where: { $0.id == id }) {
            lines[i] = line
        } else {
            lines.append(line)
        }
        lineCount = lines.count
    }
}

/// Keeps sessions in memory: demo mode and tests.
actor InMemoryHistoryStore: HistoryStoring {
    private var store: [String: HistorySession]
    private var enabled = true

    init(_ sessions: [HistorySession] = []) {
        store = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func sessions() async -> [HistorySession] { store.values.sorted { $0.startedAt > $1.startedAt } }

    func append(_ line: HistoryLine, sessionID: String, languageCode: String) async {
        guard enabled else { return }
        var s = store[sessionID] ?? HistorySession(id: sessionID, startedAt: line.at, languageCode: languageCode)
        s.upsert(line)
        store[sessionID] = s
    }

    func delete(sessionID: String) async { store[sessionID] = nil }
    func deleteAll() async { store.removeAll() }
    func setEnabled(_ on: Bool) async { enabled = on }
}

/// The file store: one JSON file per session in `directory` (Application Support/History, excluded from backup).
///
/// Writes are batched: an append marks its session dirty and schedules one flush `flushDelay` later (2 s); `flush()`
/// writes immediately (conversation stopped, app in the background). Every file is written atomically and then
/// flagged excluded from backup. A file that cannot be read is set aside as `<name>.corrupt` and logged; it never
/// stops the others from loading. Runs off the main actor.
actor FileHistoryStore: HistoryStoring {
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    let directory: URL
    private let flushDelay: Duration
    private var enabled: Bool
    private var cache: [String: HistorySession]?
    private var dirty = Set<String>()
    private var flushTask: Task<Void, Never>?
    /// Files written so far (tests check batching with it).
    private(set) var writeCount = 0
    /// Files set aside as unreadable on load.
    private(set) var corruptFiles: [String] = []

    init(directory: URL, enabled: Bool = true, flushDelay: Duration = .seconds(2)) {
        self.directory = directory
        self.enabled = enabled
        self.flushDelay = flushDelay
    }

    func setEnabled(_ on: Bool) async {
        if !on { await flush() }
        enabled = on
    }

    func sessions() async -> [HistorySession] {
        loaded().values.sorted { $0.startedAt > $1.startedAt }
    }

    func append(_ line: HistoryLine, sessionID: String, languageCode: String) async {
        guard enabled else { return }
        var all = loaded()
        var s = all[sessionID] ?? HistorySession(id: sessionID, startedAt: line.at, languageCode: languageCode)
        s.upsert(line)
        all[sessionID] = s
        cache = all
        dirty.insert(sessionID)
        scheduleFlush()
    }

    func delete(sessionID: String) async {
        var all = loaded()
        all[sessionID] = nil
        cache = all
        dirty.remove(sessionID)
        try? FileManager.default.removeItem(at: file(sessionID))
    }

    func deleteAll() async {
        cache = [:]
        dirty.removeAll()
        flushTask?.cancel()
        flushTask = nil
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard !dirty.isEmpty, let all = cache else { return }
        let ids = dirty
        dirty.removeAll()
        do {
            try ensureDirectory()
        } catch {
            Diag.log("history: no directory: \(error)")
            dirty.formUnion(ids)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for id in ids.sorted() {
            guard let s = all[id] else { continue }
            var url = file(id)
            do {
                try encoder.encode(s).write(to: url, options: .atomic)
                writeCount += 1
                Self.excludeFromBackup(&url)
            } catch {
                Diag.log("history: write \(id) failed: \(error)")
                dirty.insert(id)
            }
        }
    }

    // MARK: Internals

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = flushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func ensureDirectory() throws {
        var dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.excludeFromBackup(&dir)
    }

    private static func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The sessions, read from disk on first use.
    private func loaded() -> [String: HistorySession] {
        if let cache { return cache }
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all: [String: HistorySession] = [:]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            do {
                var s = try decoder.decode(HistorySession.self, from: Data(contentsOf: url))
                // The file name is the id; a hand-edited id inside must not make two files collide
                s.id = url.deletingPathExtension().lastPathComponent
                s.lineCount = s.lines.count
                all[s.id] = s
            } catch {
                Diag.log("history: unreadable \(url.lastPathComponent), set aside: \(error)")
                corruptFiles.append(url.lastPathComponent)
                try? fm.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            }
        }
        cache = all
        return all
    }
}

// MARK: Recorder (UIState → store)

/// Mirrors the transcript into the store: a session starts with the first new line after a start, a language change
/// or a stop, and every new or changed line (by `UILine.id`) is upserted into the session it first went to (a late
/// translation after a stop still lands in its own session); the store batches the writes. A line of mine waits for
/// its translation (a phrase still being spoken is not history); theirs are final when they appear.
@MainActor
final class HistoryRecorder {
    private let store: any HistoryStoring
    private let calendar: Calendar
    private var seen: [String: (line: UILine, session: String)] = [:]
    private(set) var sessionID: String?
    private var sessionLanguage: String?
    private var wasListening = false

    init(store: any HistoryStoring, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    /// Feeds the current transcript; returns the lines handed to the store (tests).
    @discardableResult
    func sync(lines: [UILine], languageCode: String?, enabled: Bool) -> [HistoryLine] {
        guard enabled, let code = languageCode else { return [] }
        if sessionLanguage != nil && code != sessionLanguage { endSession() }
        var out: [HistoryLine] = []
        for line in lines {
            guard line.mine ? !line.target.isEmpty : true, !line.source.isEmpty else { continue }
            let known = seen[line.id]
            if let known, known.line.source == line.source, known.line.target == line.target { continue }
            let id: String
            if let known {
                id = known.session
            } else {
                id = sessionID ?? HistorySession.id(startedAt: line.at, languageCode: code, calendar: calendar)
                sessionID = id
                sessionLanguage = code
            }
            seen[line.id] = (line, id)
            let h = HistoryLine(mine: line.mine, source: line.source, target: line.target, at: line.at, id: line.id)
            out.append(h)
            enqueue { await $0.append(h, sessionID: id, languageCode: code) }
        }
        return out
    }

    /// Notes the conversation on/off; a stop ends the session.
    func noteListening(_ listening: Bool) {
        if wasListening && !listening { endSession() }
        wasListening = listening
    }

    /// The conversation stopped: write now; the next new line starts a new session.
    func endSession() {
        guard sessionID != nil else { return }
        sessionID = nil
        sessionLanguage = nil
        enqueue { await $0.flush() }
    }

    /// Store calls run one after the other, in the order they were made (a newer version of a line never loses to
    /// an older one).
    private var chain: Task<Void, Never>?

    private func enqueue(_ work: @escaping @Sendable (any HistoryStoring) async -> Void) {
        let previous = chain, store = self.store
        chain = Task {
            await previous?.value
            await work(store)
        }
    }

    /// Waits for every store call made so far (tests).
    func settle() async { await chain?.value }

    /// Watches `ui` (lines, language, listening, the setting) for as long as both live.
    func observe(_ ui: UIState) {
        noteListening(ui.listening)
        sync(lines: ui.lines, languageCode: ui.languageCode, enabled: ui.saveHistory)
        withObservationTracking {
            _ = ui.lines
            _ = ui.languageCode
            _ = ui.saveHistory
            _ = ui.listening
        } onChange: { [weak self, weak ui] in
            Task { @MainActor in
                guard let self, let ui else { return }
                self.observe(ui)
            }
        }
    }
}
