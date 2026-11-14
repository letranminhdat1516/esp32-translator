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
    /// The transcript line it came from, so a later "Sửa" on that line lands on this item.
    var lineID: String? = nil
    /// The translation as the user fixed it with "Sửa"; nil when never edited.
    var correctedTranslation: String? = nil

    var side: Side { mine ? .mine : .theirs }

    /// The review row's title: "heard → expected", or "heard → corrected translation" for a "Sửa" without one.
    var reviewTitle: String {
        let fix = expected.isEmpty ? (correctedTranslation ?? "") : expected
        return fix.isEmpty ? heard : heard + " \u{2192} " + fix
    }

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
    /// The translation as fixed with "Sửa", when there was one.
    var correctedTranslation: String? = nil
}

/// A built export folder and the items in it; they are marked sent only once the share sheet reports it was shared.
struct FeedbackExport: Hashable, Sendable {
    var folder: URL
    var itemIDs: [String]
}

/// The local queue of reports; export builds `feedback-<date>/` with `items.json` and the WAVs for the share sheet.
protocol FeedbackQueueing: Sendable {
    func items() async -> [FeedbackItem]
    func add(_ item: FeedbackItem, clip: Data?) async
    /// Replaces the queued item with the same id (its clip stays); unknown ids are ignored.
    func update(_ item: FeedbackItem) async
    func setSelected(_ id: String, _ selected: Bool) async
    func removeAll() async
    /// Removes the items already exported, their clips and every export folder ("Xoá dữ liệu đã gửi").
    func removeSent() async
    /// Builds the folder to share, or nil when nothing is selected. Marks nothing sent (see `markSent`).
    func exportBundle() async throws -> FeedbackExport?
    /// The share sheet reported the export was shared: its items are sent.
    func markSent(_ export: FeedbackExport) async
    /// The share was cancelled: the export folder (and its zip) goes, nothing is marked sent.
    func discardExport(_ export: FeedbackExport) async
    /// The queued clip of `id` on disk.
    func clipURL(_ id: String) async -> URL?
    /// The clip of `id` for playback: from disk, or from memory for an unselected sensitive item.
    func clipData(_ id: String) async -> Data?
}

extension FeedbackQueueing {
    func removeSent() async {}
    func markSent(_ export: FeedbackExport) async {}
    func discardExport(_ export: FeedbackExport) async {}
    func clipURL(_ id: String) async -> URL? { nil }
    func clipData(_ id: String) async -> Data? { nil }
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

    func update(_ item: FeedbackItem) async {
        guard let i = list.firstIndex(where: { $0.id == item.id }) else { return }
        list[i] = item
    }

    func setSelected(_ id: String, _ selected: Bool) async {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].selected = selected
    }

    func removeAll() async { list.removeAll() }
    func removeSent() async { list.removeAll { $0.sentAt != nil } }
    func exportBundle() async throws -> FeedbackExport? { nil }

    /// How many items an export would send (the "Gửi n câu" button).
    static func selectedCount(_ items: [FeedbackItem]) -> Int { FeedbackItem.selectedCount(items) }
}

/// The file queue in `directory` (Application Support/Feedback, excluded from backup):
/// `queue.json` (the items), `clips/<id>.wav`, and `exports/feedback-<yyyyMMdd-HHmmss>/` (`items.json` + `NN.wav`)
/// built for the share sheet. An unreadable `queue.json` is set aside as `queue.corrupt-<n>.json` and logged.
///
/// The clip of an item that is sensitive and not selected is never written: it is held in memory until the user
/// selects the item (then written), and an item that becomes sensitive and unselected has its file moved back into
/// memory. A held clip is gone when the app quits.
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
    /// Clips of unselected sensitive items (memory only).
    private var heldClips: [String: Data] = [:]

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
            item.clipSeconds = item.clipSeconds ?? WAV.duration(clip)
            heldClips[item.id] = clip
        } else {
            item.clipSeconds = nil
        }
        list.append(item)
        settleClip(list.count - 1)
        save()
    }

    func update(_ item: FeedbackItem) async {
        guard let i = list.firstIndex(where: { $0.id == item.id }) else { return }
        var item = item
        item.clipFile = list[i].clipFile
        item.clipSeconds = list[i].clipSeconds
        list[i] = item
        settleClip(i)
        save()
    }

    func setSelected(_ id: String, _ selected: Bool) async {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].selected = selected
        settleClip(i)
        save()
    }

    func removeAll() async {
        list.removeAll()
        heldClips.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func removeSent() async {
        let fm = FileManager.default
        for item in list where item.sentAt != nil {
            if let f = item.clipFile { try? fm.removeItem(at: clipsDirectory.appendingPathComponent(f)) }
        }
        for item in list where item.sentAt != nil { heldClips[item.id] = nil }
        list.removeAll { $0.sentAt != nil }
        try? fm.removeItem(at: exportsDirectory)
        save()
    }

    func clipURL(_ id: String) async -> URL? {
        guard let f = list.first(where: { $0.id == id })?.clipFile else { return nil }
        let url = clipsDirectory.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func clipData(_ id: String) async -> Data? {
        if let held = heldClips[id] { return held }
        guard let url = await clipURL(id) else { return nil }
        return try? Data(contentsOf: url)
    }

    func exportBundle() async throws -> FeedbackExport? {
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
                                              at: item.at, correctedTranslation: item.correctedTranslation))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: folder.appendingPathComponent("items.json"), options: .atomic)
        return FeedbackExport(folder: folder, itemIDs: chosen.map(\.id))
    }

    func markSent(_ export: FeedbackExport) async {
        let ids = Set(export.itemIDs), now = clock()
        for i in list.indices where ids.contains(list[i].id) { list[i].sentAt = now }
        save()
    }

    func discardExport(_ export: FeedbackExport) async {
        let fm = FileManager.default
        // Only folders this queue built (and the zip made beside one)
        guard export.folder.deletingLastPathComponent().standardizedFileURL == exportsDirectory.standardizedFileURL
        else { return }
        try? fm.removeItem(at: export.folder)
        try? fm.removeItem(at: export.folder.deletingLastPathComponent()
            .appendingPathComponent(export.folder.lastPathComponent + ".zip"))
    }

    // MARK: Internals

    /// Puts the clip of item `i` where it belongs: memory while the item is sensitive and unselected, the clips
    /// folder otherwise.
    private func settleClip(_ i: Int) {
        let item = list[i]
        let fm = FileManager.default
        if item.sensitive && !item.selected {
            guard let f = item.clipFile else { return }
            let url = clipsDirectory.appendingPathComponent(f)
            if let data = try? Data(contentsOf: url) { heldClips[item.id] = data }
            try? fm.removeItem(at: url)
            list[i].clipFile = nil
        } else if let clip = heldClips[item.id] {
            do {
                try ensure(clipsDirectory)
                let name = "\(Self.safeName(item.id)).wav"
                try clip.write(to: clipsDirectory.appendingPathComponent(name), options: .atomic)
                list[i].clipFile = name
                heldClips[item.id] = nil
            } catch {
                Diag.log("feedback: clip write failed: \(error)")
            }
        }
    }

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
            // A clip held in memory (unselected sensitive item) did not survive the restart: no audio shown
            return try decoder.decode([FeedbackItem].self, from: Data(contentsOf: file)).map { item in
                var item = item
                if item.clipFile == nil { item.clipSeconds = nil }
                return item
            }
        } catch {
            Diag.log("feedback: unreadable queue, set aside: \(error)")
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("queue.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
    }
}
