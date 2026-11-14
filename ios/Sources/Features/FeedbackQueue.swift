import Foundation

/// One "Báo dịch sai" report: what was heard, its translation, what it should have been, and an optional clip.
struct FeedbackItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var mine: Bool
    /// What the recognizer produced ("a mốc xi xi lin").
    var heard: String
    /// What the user says it should be ("amoxicillin").
    var expected: String
    /// Length of the clip in seconds; nil without audio.
    var clipSeconds: Double?
    /// File name of the clip inside the queue folder.
    var clipFile: String?
    /// May contain a password or similar: not selected by default.
    var sensitive = false
    var selected = true
    var at: Date
    /// The translation that was shown/spoken for `heard`.
    var target: String = ""
    /// The other language of the conversation ("en").
    var languageCode: String = ""
    /// When it was last exported for the share sheet; nil while only queued.
    var sentAt: Date? = nil

    var side: Side { mine ? .mine : .theirs }

    /// A line that may hold a secret (a password, a code): it is queued unselected and marked.
    static func looksSensitive(_ texts: String...) -> Bool {
        let words = ["mật khẩu", "mat khau", "password", "passcode", "mã pin", "pin code", "otp", "mã xác nhận",
                     "wifi pass", "wi-fi pass", "số thẻ", "card number", "cvv"]
        for t in texts {
            let lower = t.lowercased()
            if words.contains(where: lower.contains) { return true }
            // 4 or more digits in a row (a code, a card number)
            var run = 0
            for ch in lower {
                run = ch.isNumber ? run + 1 : 0
                if run >= 4 { return true }
            }
        }
        return false
    }
}

/// One entry of `items.json` in an export folder.
struct FeedbackExportItem: Codable, Hashable, Sendable {
    var index: Int
    var side: String
    var language: String
    var heard: String
    var translation: String
    var expected: String
    var durationSeconds: Double?
    var wav: String?
    var at: Date
}

/// The local queue of reports; export builds `feedback-<date>/` with `items.json` and the WAVs for the share sheet.
protocol FeedbackQueueing: Sendable {
    func items() async -> [FeedbackItem]
    func add(_ item: FeedbackItem, clip: Data?) async
    func setSelected(_ id: String, _ selected: Bool) async
    func removeAll() async
    /// Removes the items already exported, their clips and every export folder ("Xoá dữ liệu đã gửi").
    func removeSent() async
    /// The folder to share, or nil when nothing is selected. Marks the exported items sent.
    func exportBundle() async throws -> URL?
    /// The queued clip of `id`, for playback.
    func clipURL(_ id: String) async -> URL?
}

extension FeedbackQueueing {
    func removeSent() async {}
    func clipURL(_ id: String) async -> URL? { nil }
}

extension FeedbackItem {
    /// How many items an export would send (the "Gửi n câu" button).
    static func selectedCount(_ items: [FeedbackItem]) -> Int { items.filter(\.selected).count }
}

actor InMemoryFeedbackQueue: FeedbackQueueing {
    private var list: [FeedbackItem]

    init(_ items: [FeedbackItem] = []) { list = items }

    func items() async -> [FeedbackItem] { list }
    func add(_ item: FeedbackItem, clip: Data?) async { list.append(item) }

    func setSelected(_ id: String, _ selected: Bool) async {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].selected = selected
    }

    func removeAll() async { list.removeAll() }
    func removeSent() async { list.removeAll { $0.sentAt != nil } }
    func exportBundle() async throws -> URL? { nil }

    /// How many items an export would send (the "Gửi n câu" button).
    static func selectedCount(_ items: [FeedbackItem]) -> Int { FeedbackItem.selectedCount(items) }
}

/// The file queue in `directory` (Application Support/Feedback, excluded from backup):
/// `queue.json` (the items), `clips/<id>.wav`, and `exports/feedback-<yyyyMMdd-HHmmss>/` (`items.json` + `NN.wav`)
/// built for the share sheet. An unreadable `queue.json` is set aside as `queue.corrupt-<n>.json` and logged.
actor FileFeedbackQueue: FeedbackQueueing {
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: true)
            .appendingPathComponent("Feedback", isDirectory: true)
    }

    let directory: URL
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private var list: [FeedbackItem]

    init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.directory = directory
        self.clock = clock
        self.calendar = calendar
        list = Self.load(directory.appendingPathComponent("queue.json"))
    }

    var clipsDirectory: URL { directory.appendingPathComponent("clips", isDirectory: true) }
    var exportsDirectory: URL { directory.appendingPathComponent("exports", isDirectory: true) }

    func items() async -> [FeedbackItem] { list }

    func add(_ item: FeedbackItem, clip: Data?) async {
        var item = item
        item.clipFile = nil
        if let clip {
            do {
                try ensure(clipsDirectory)
                let name = "\(Self.safeName(item.id)).wav"
                try clip.write(to: clipsDirectory.appendingPathComponent(name), options: .atomic)
                item.clipFile = name
                item.clipSeconds = item.clipSeconds ?? WAV.duration(clip)
            } catch {
                Diag.log("feedback: clip write failed: \(error)")
            }
        }
        list.append(item)
        save()
    }

    func setSelected(_ id: String, _ selected: Bool) async {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].selected = selected
        save()
    }

    func removeAll() async {
        list.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func removeSent() async {
        let fm = FileManager.default
        for item in list where item.sentAt != nil {
            if let f = item.clipFile { try? fm.removeItem(at: clipsDirectory.appendingPathComponent(f)) }
        }
        list.removeAll { $0.sentAt != nil }
        try? fm.removeItem(at: exportsDirectory)
        save()
    }

    func clipURL(_ id: String) async -> URL? {
        guard let f = list.first(where: { $0.id == id })?.clipFile else { return nil }
        let url = clipsDirectory.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func exportBundle() async throws -> URL? {
        let chosen = list.filter(\.selected)
        guard !chosen.isEmpty else { return nil }
        let now = clock()
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let name = String(format: "feedback-%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let folder = exportsDirectory.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try ensure(exportsDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [FeedbackExportItem] = []
        for (i, item) in chosen.enumerated() {
            var wav: String?
            if let f = item.clipFile {
                let src = clipsDirectory.appendingPathComponent(f)
                if fm.fileExists(atPath: src.path) {
                    let dst = String(format: "%02d.wav", i + 1)
                    try fm.copyItem(at: src, to: folder.appendingPathComponent(dst))
                    wav = dst
                }
            }
            entries.append(FeedbackExportItem(index: i + 1, side: item.side.rawValue, language: item.languageCode,
                                              heard: item.heard, translation: item.target, expected: item.expected,
                                              durationSeconds: wav == nil ? nil : item.clipSeconds, wav: wav,
                                              at: item.at))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: folder.appendingPathComponent("items.json"), options: .atomic)
        let ids = Set(chosen.map(\.id))
        for i in list.indices where ids.contains(list[i].id) { list[i].sentAt = now }
        save()
        return folder
    }

    // MARK: Internals

    private static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    private func ensure(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private func save() {
        do {
            try ensure(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(list).write(to: directory.appendingPathComponent("queue.json"), options: .atomic)
        } catch {
            Diag.log("feedback: save failed: \(error)")
        }
    }

    private static func load(_ file: URL) -> [FeedbackItem] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([FeedbackItem].self, from: Data(contentsOf: file))
        } catch {
            Diag.log("feedback: unreadable queue, set aside: \(error)")
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("queue.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
    }
}
