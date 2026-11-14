import AVFAudio
import Foundation
import Testing
@testable import TranslatorCore

// Track C: HistoryStore, AudioClipRecorder, FeedbackQueue and the DataCoordinator glue.

private func tempDir(_ name: String = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("data-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func line(_ s: String, mine: Bool = false, at t: TimeInterval = 0, id: String? = nil) -> HistoryLine {
    HistoryLine(mine: mine, source: s, target: s.uppercased(), at: Date(timeIntervalSince1970: 1_000_000 + t), id: id)
}

private func isExcludedFromBackup(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
}

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    var t: TimeInterval = 100
    var clock: ClosureSessionClock { ClosureSessionClock { [unowned self] in self.t } }
}

// MARK: HistoryStore

@Suite struct HistoryStoreTests {
    @Test func batchesWritesUntilFlush() async throws {
        let dir = tempDir()
        let store = FileHistoryStore(directory: dir, flushDelay: .seconds(60))
        for i in 0..<3 { await store.append(line("l\(i)", at: Double(i)), sessionID: "s1", languageCode: "en") }
        #expect(await store.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s1.json").path))
        await store.flush()
        #expect(await store.writeCount == 1)
        let file = dir.appendingPathComponent("s1.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(isExcludedFromBackup(file))
        #expect(isExcludedFromBackup(dir))
        // A second flush with nothing new writes nothing
        await store.flush()
        #expect(await store.writeCount == 1)
        // Reopened: the lines come back from disk
        let reopened = FileHistoryStore(directory: dir)
        let sessions = await reopened.sessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].lines.map(\.source) == ["l0", "l1", "l2"])
        #expect(sessions[0].lineCount == 3)
    }

    @Test func flushesByItselfAfterTheDelay() async throws {
        let dir = tempDir()
        let store = FileHistoryStore(directory: dir, flushDelay: .milliseconds(50))
        await store.append(line("a"), sessionID: "s", languageCode: "en")
        await store.append(line("b", at: 1), sessionID: "s", languageCode: "en")
        #expect(await store.writeCount == 0)
        // Wait for the scheduled flush (generous: the suite runs in parallel)
        for _ in 0..<100 where await store.writeCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await store.writeCount == 1)   // two appends, one write
    }

    @Test func gatedBySetting() async {
        let dir = tempDir()
        let store = FileHistoryStore(directory: dir, enabled: false)
        await store.append(line("x"), sessionID: "s", languageCode: "en")
        await store.flush()
        #expect(await store.sessions().isEmpty)
        #expect(await store.writeCount == 0)
        await store.setEnabled(true)
        await store.append(line("y"), sessionID: "s", languageCode: "en")
        #expect(await store.sessions().first?.lines.map(\.source) == ["y"])
        // Turning it off writes what was pending, then drops new lines
        await store.setEnabled(false)
        #expect(await store.writeCount == 1)
        await store.append(line("z"), sessionID: "s", languageCode: "en")
        #expect(await store.sessions().first?.lineCount == 1)
    }

    @Test func upsertsByLineID() async {
        let store = FileHistoryStore(directory: tempDir())
        await store.append(line("draft", mine: true, id: "m-1"), sessionID: "s", languageCode: "en")
        await store.append(line("final", mine: true, id: "m-1"), sessionID: "s", languageCode: "en")
        await store.append(line("other", id: "t-1"), sessionID: "s", languageCode: "en")
        #expect(await store.sessions().first?.lines.map(\.source) == ["final", "other"])
    }

    @Test func groupsByDayNewestFirst() async {
        let store = FileHistoryStore(directory: tempDir())
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2025, month: 11, day: 15, hour: 14, minute: 21))!
        let today = now.addingTimeInterval(-600)
        let older = cal.date(byAdding: .day, value: -2, to: now)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        for (id, at) in [("a", older), ("b", today), ("c", yesterday), ("d", today.addingTimeInterval(-60))] {
            await store.append(HistoryLine(mine: false, source: id, target: id, at: at), sessionID: id, languageCode: "en")
        }
        let sections = HistoryFormatting.sections(await store.sessions(), now: now)
        #expect(sections.map(\.title).prefix(2) == ["Hôm nay", "Hôm qua"])
        #expect(sections.count == 3)
        #expect(sections[0].sessions.map(\.id) == ["b", "d"])
    }

    @Test func corruptFileIsSkippedAndSetAside() async throws {
        let dir = tempDir()
        let good = FileHistoryStore(directory: dir)
        await good.append(line("ok"), sessionID: "good", languageCode: "en")
        await good.flush()
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        let store = FileHistoryStore(directory: dir)
        let sessions = await store.sessions()
        #expect(sessions.map(\.id) == ["good"])
        #expect(await store.corruptFiles == ["bad.json"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.json.corrupt").path))
    }

    @Test func deleteOneAndAll() async {
        let dir = tempDir()
        let store = FileHistoryStore(directory: dir)
        await store.append(line("a"), sessionID: "a", languageCode: "en")
        await store.append(line("b", at: 10), sessionID: "b", languageCode: "en")
        await store.flush()
        await store.delete(sessionID: "a")
        #expect(await store.sessions().map(\.id) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.json").path))
        await store.deleteAll()
        #expect(await store.sessions().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
        #expect(await FileHistoryStore(directory: dir).sessions().isEmpty)
    }

    @Test func searchMatchesAnyPhrase() {
        let s = HistorySession(id: "x", startedAt: Date(), languageCode: "en",
                               lines: [HistoryLine(mine: false, source: "Where is the station?", target: "Ga ở đâu?", at: Date())])
        #expect(s.matches("station"))
        #expect(s.matches("GA Ở"))
        #expect(s.matches("  "))
        #expect(!s.matches("airport"))
    }
}

@MainActor @Suite struct HistoryRecorderTests {
    private func ui(_ code: String = "en") -> UIState {
        let ui = UIState()
        ui.languageCode = code
        return ui
    }

    private func uiLine(_ id: String, mine: Bool, _ source: String, _ target: String, at t: TimeInterval = 0) -> UILine {
        UILine(id: id, mine: mine, source: source, target: target, at: DemoData.now.addingTimeInterval(t))
    }

    @Test func mirrorsFinishedLinesIntoOneSession() async {
        let store = InMemoryHistoryStore()
        let rec = HistoryRecorder(store: store)
        var lines = [uiLine("t-1", mine: false, "Hi", "Chào"), uiLine("m-1", mine: true, "Dạ", "", at: 1)]
        #expect(rec.sync(lines: lines, languageCode: "en", enabled: true).count == 1)   // mine waits for its translation
        #expect(rec.sync(lines: lines, languageCode: "en", enabled: true).isEmpty)      // nothing changed
        lines[1].target = "Yes"
        #expect(rec.sync(lines: lines, languageCode: "en", enabled: true).count == 1)
        await rec.settle()
        let sessions = await store.sessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].id == HistorySession.id(startedAt: lines[0].at, languageCode: "en"))
        #expect(sessions[0].lines.map(\.target) == ["Chào", "Yes"])
    }

    @Test func stopOrLanguageChangeStartsANewSession() async {
        let store = InMemoryHistoryStore()
        let rec = HistoryRecorder(store: store)
        rec.noteListening(true)
        rec.sync(lines: [uiLine("t-1", mine: false, "a", "A")], languageCode: "en", enabled: true)
        rec.noteListening(false)
        rec.sync(lines: [uiLine("t-1", mine: false, "a", "A"), uiLine("t-2", mine: false, "b", "B", at: 5)],
                 languageCode: "en", enabled: true)
        rec.sync(lines: [uiLine("t-3", mine: false, "c", "C", at: 9)], languageCode: "ja", enabled: true)
        await rec.settle()
        let sessions = await store.sessions()
        #expect(sessions.count == 3)
        #expect(Set(sessions.map(\.languageCode)) == ["en", "ja"])
    }

    @Test func offRecordsNothing() async {
        let store = InMemoryHistoryStore()
        let rec = HistoryRecorder(store: store)
        #expect(rec.sync(lines: [uiLine("t-1", mine: false, "a", "A")], languageCode: "en", enabled: false).isEmpty)
        #expect(rec.sync(lines: [uiLine("t-1", mine: false, "a", "A")], languageCode: nil, enabled: true).isEmpty)
        await rec.settle()
        #expect(await store.sessions().isEmpty)
    }

    /// Lines spoken while "Lưu lịch sử" was off never reach the store, not even when it is turned back on (or when
    /// their translation arrives after that).
    @Test func linesFromWhileOffStayUnsavedAfterTurningBackOn() async {
        let store = InMemoryHistoryStore()
        let rec = HistoryRecorder(store: store)
        #expect(rec.sync(lines: [uiLine("t-1", mine: false, "a", "A")], languageCode: "en", enabled: true).count == 1)
        var lines = [uiLine("t-1", mine: false, "a", "A"), uiLine("t-2", mine: false, "secret", "BÍ MẬT", at: 1),
                     uiLine("m-1", mine: true, "mật khẩu", "", at: 2)]
        #expect(rec.sync(lines: lines, languageCode: "en", enabled: false).isEmpty)
        lines[2].target = "the password"   // its translation lands after the switch is back on
        lines.append(uiLine("t-3", mine: false, "b", "B", at: 3))
        let saved = rec.sync(lines: lines, languageCode: "en", enabled: true)
        #expect(saved.map(\.id) == ["t-3"])
        await rec.settle()
        #expect(await store.sessions().flatMap(\.lines).map(\.source) == ["a", "b"])
    }
}

// MARK: AudioClipRecorder

@Suite struct AudioClipRecorderTests {
    @Test func ringWrapsAndDropsOverwrittenAudio() {
        let c = ManualClock()
        let rec = RingAudioClipRecorder(clock: c.clock, seconds: 1)
        // Three contiguous 0.5 s chunks with values 1, 2, 3: the first is overwritten
        for v in 1...3 {
            c.t += 0.5
            rec.append([Int16](repeating: Int16(v), count: 8_000), sampleRate: 16_000, side: .theirs)
        }
        #expect(rec.clip(100.0...100.5, side: .theirs) == nil)
        let second = rec.clip(100.5...101.0, side: .theirs).map(Self.samples)
        #expect(second?.count == 8_000)
        #expect(second?.allSatisfy { $0 == 2 } == true)
        let both = rec.clip(100.5...101.5, side: .theirs).map(Self.samples)
        #expect(both?.count == 16_000)
        #expect(both?.first == 2 && both?.last == 3)
        // The other side heard nothing
        #expect(rec.clip(100.5...101.5, side: .mine) == nil)
    }

    @Test func clipRangesAndGaps() {
        let c = ManualClock()
        let rec = RingAudioClipRecorder(clock: c.clock, seconds: 20)
        rec.append([Int16](repeating: 7, count: 16_000), sampleRate: 16_000, side: .mine, endingAt: 11)   // 10…11
        rec.append([Int16](repeating: 9, count: 8_000), sampleRate: 16_000, side: .mine, endingAt: 12.5)  // 12…12.5
        // Inside the first span
        let a = rec.clip(10.25...10.5, side: .mine).map(Self.samples)
        #expect(a?.count == 4_000)
        // Across the gap: silence between the spans
        let b = rec.clip(10.5...12.25, side: .mine).map(Self.samples) ?? []
        #expect(b.count == 8_000 + 16_000 + 4_000)
        #expect(b.prefix(8_000).allSatisfy { $0 == 7 })
        #expect(b.dropFirst(8_000).prefix(16_000).allSatisfy { $0 == 0 })
        #expect(b.suffix(4_000).allSatisfy { $0 == 9 })
        // Before anything was heard, the range is trimmed to the audio
        #expect(rec.clip(5...10.5, side: .mine).map(Self.samples)?.count == 8_000)
        #expect(rec.clip(1...5, side: .mine) == nil)
        rec.reset()
        #expect(rec.clip(10...11, side: .mine) == nil)
    }

    @Test func contiguousChunksJoinIntoOneSpan() {
        let c = ManualClock()
        let rec = RingAudioClipRecorder(clock: c.clock)
        for _ in 0..<10 {
            c.t += 0.02
            rec.append([Int16](repeating: 1, count: 320), sampleRate: 16_000, side: .theirs)
        }
        #expect(rec.clip(100...100.2, side: .theirs).map(Self.samples)?.count == 3_200)
    }

    @Test func resamplesOtherRates() {
        let c = ManualClock()
        let rec = RingAudioClipRecorder(clock: c.clock)
        rec.append([Int16](repeating: 5, count: 8_000), sampleRate: 8_000, side: .theirs, endingAt: 101)
        let s = rec.clip(100...101, side: .theirs).map(Self.samples)
        #expect(s?.count == 16_000)
        #expect(RingAudioClipRecorder.resample([0, 100], from: 8_000, to: 16_000) == [0, 33, 67, 100])
    }

    @Test func wavHeader() {
        let wav = WAV.encode([1, -1, 300], sampleRate: 16_000)
        #expect(wav.count == 44 + 6)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        func u32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ at: Int) -> UInt16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        #expect(u32(4) == 36 + 6)
        #expect(u32(16) == 16)
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // mono
        #expect(u32(24) == 16_000)
        #expect(u32(28) == 32_000)
        #expect(u16(32) == 2)
        #expect(u16(34) == 16)
        #expect(u32(40) == 6)
        #expect(Self.samples(wav) == [1, -1, 300])
        #expect(WAV.duration(WAV.encode([Int16](repeating: 0, count: 32_000), sampleRate: 16_000)) == 2)
    }

    static func samples(_ wav: Data) -> [Int16] {
        wav.dropFirst(44).withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map { Int16(bitPattern: UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8) }
        }
    }
}

// MARK: FeedbackQueue

@Suite struct FeedbackQueueTests {
    private static func item(_ id: String, selected: Bool = true, mine: Bool = true) -> FeedbackItem {
        FeedbackItem(id: id, mine: mine, heard: "heard \(id)", expected: "fixed \(id)", selected: selected,
                     at: Date(timeIntervalSince1970: 1_700_000_000), target: "target \(id)", languageCode: "en")
    }

    private static let fixedClock: @Sendable () -> Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 15, 9, 41, 7)
        return Calendar.current.date(from: c)!
    }

    @Test func updateKeepsTheClipPersistsAndExportsTheCorrectedTranslation() async throws {
        let dir = tempDir()
        let q = FileFeedbackQueue(directory: dir, clock: Self.fixedClock)
        let clip = WAV.encode([Int16](repeating: 3, count: 16_000), sampleRate: 16_000)
        await q.add(Self.item("a"), clip: clip)
        var changed = try #require(await q.items().first)
        changed.correctedTranslation = "better a"
        changed.clipFile = nil   // the queue owns the clip reference
        await q.update(changed)
        await q.update(Self.item("missing"))   // unknown ids are ignored
        #expect(await q.items().count == 1)
        #expect(await q.items().first?.correctedTranslation == "better a")
        #expect(await q.clipURL("a") != nil)
        #expect(await FileFeedbackQueue(directory: dir).items().first?.correctedTranslation == "better a")

        let folder = try #require(try await q.exportBundle())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([FeedbackExportItem].self, from: Data(contentsOf: folder.appendingPathComponent("items.json")))
        #expect(entries.first?.correctedTranslation == "better a")
        #expect(entries.first?.wav == "01.wav")
    }

    @Test func reviewTitle() {
        var item = Self.item("a")
        #expect(item.reviewTitle == "heard a \u{2192} fixed a")
        item.expected = ""
        #expect(item.reviewTitle == "heard a")
        item.correctedTranslation = "better a"
        #expect(item.reviewTitle == "heard a \u{2192} better a")
    }

    @Test func itemsSavedBeforeCorrectionsStillLoad() throws {
        let old = #"[{"id":"x","mine":true,"heard":"h","expected":"e","sensitive":false,"selected":true,"at":"2026-11-15T09:41:07Z","target":"t","languageCode":"en"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([FeedbackItem].self, from: Data(old.utf8))
        #expect(items.first?.lineID == nil && items.first?.correctedTranslation == nil)
    }

    @Test func exportBundleContents() async throws {
        let dir = tempDir()
        let q = FileFeedbackQueue(directory: dir, clock: Self.fixedClock)
        let clipA = WAV.encode([Int16](repeating: 3, count: 16_000), sampleRate: 16_000)
        let clipC = WAV.encode([Int16](repeating: 4, count: 8_000), sampleRate: 16_000)
        await q.add(Self.item("a"), clip: clipA)
        await q.add(Self.item("b", selected: false), clip: clipA)
        await q.add(Self.item("c", mine: false), clip: clipC)
        await q.add(Self.item("d"), clip: nil)
        #expect(await q.items().first?.clipSeconds == 1)
        #expect(await q.clipURL("a") != nil)
        #expect(await q.clipURL("d") == nil)

        let folder = try #require(try await q.exportBundle())
        #expect(folder.lastPathComponent == "feedback-20261115-094107")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["01.wav", "02.wav", "items.json"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("01.wav")) == clipA)
        #expect(try Data(contentsOf: folder.appendingPathComponent("02.wav")) == clipC)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([FeedbackExportItem].self, from: Data(contentsOf: folder.appendingPathComponent("items.json")))
        #expect(entries.map(\.heard) == ["heard a", "heard c", "heard d"])
        #expect(entries.map(\.wav) == ["01.wav", "02.wav", nil])
        #expect(entries.map(\.side) == ["mine", "theirs", "mine"])
        #expect(entries[0].translation == "target a" && entries[0].expected == "fixed a" && entries[0].language == "en")
        #expect(entries[1].durationSeconds == 0.5)
        #expect(isExcludedFromBackup(dir))

        let items = await q.items()
        #expect(items.filter { $0.sentAt != nil }.map(\.id) == ["a", "c", "d"])
        // Persisted
        #expect(await FileFeedbackQueue(directory: dir).items().count == 4)
    }

    @Test func nothingSelectedExportsNothing() async throws {
        let q = FileFeedbackQueue(directory: tempDir())
        await q.add(Self.item("a", selected: false), clip: nil)
        #expect(try await q.exportBundle() == nil)
        await q.setSelected("a", true)
        #expect(try await q.exportBundle() != nil)
    }

    @Test func removeSentDeletesExportsAndTheirClips() async throws {
        let dir = tempDir()
        let q = FileFeedbackQueue(directory: dir)
        let clip = WAV.encode([1, 2, 3], sampleRate: 16_000)
        await q.add(Self.item("a"), clip: clip)
        await q.add(Self.item("b", selected: false), clip: clip)
        let folder = try #require(try await q.exportBundle())
        let clipA = try #require(await q.clipURL("a"))
        await q.removeSent()
        #expect(await q.items().map(\.id) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: clipA.path))
        #expect(await q.clipURL("b") != nil)
        await q.removeAll()
        #expect(await q.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(await FileFeedbackQueue(directory: dir).items().isEmpty)
    }

    @Test func corruptQueueStartsEmpty() async throws {
        let dir = tempDir()
        try Data("[{".utf8).write(to: dir.appendingPathComponent("queue.json"))
        let q = FileFeedbackQueue(directory: dir)
        #expect(await q.items().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("queue.corrupt-") })
    }

    @Test func sensitiveHeuristic() {
        #expect(FeedbackItem.looksSensitive("mật khẩu wifi là gì"))
        #expect(FeedbackItem.looksSensitive("the code is 4821"))
        #expect(FeedbackItem.looksSensitive("ok", "My PASSWORD"))
        #expect(!FeedbackItem.looksSensitive("phòng 12 tầng 3"))
    }
}

// MARK: DataCoordinator

@MainActor @Suite struct DataCoordinatorTests {
    private func rig(share: Bool) -> (DataCoordinator, UIState, AppServices, UserDefaults, ManualClock, RingAudioClipRecorder) {
        let defaults = UserDefaults(suiteName: "data-tests-\(UUID().uuidString)")!
        if share { defaults.set(true, forKey: DataSettings.shareKey) }
        let clock = ManualClock()
        let recorder = RingAudioClipRecorder(clock: clock.clock)
        let ui = UIState()
        ui.languageCode = "en"
        let services = AppServices(recorder: recorder, appVersion: "t")
        var n = 0
        let data = DataCoordinator(ui: ui, services: services, defaults: defaults, newID: { n += 1; return "id\(n)" })
        data.bind(observeHistory: false)
        return (data, ui, services, defaults, clock, recorder)
    }

    private func flagged(_ range: ClosedRange<TimeInterval>?) -> UILine {
        var l = UILine(id: "t-1", mine: false, source: "Ben Thanh", target: "Bến Thành", at: DemoData.now)
        l.audioRange = range
        return l
    }

    @Test func settingsDefaultsAndPersistence() {
        let (data, ui, _, defaults, _, _) = rig(share: false)
        defer { withExtendedLifetime(data) {} }
        #expect(ui.saveHistory == true)
        #expect(ui.shareToImprove == false)
        ui.setSaveHistory(false)
        ui.setShareToImprove(true)
        #expect(DataSettings.saveHistory(defaults) == false)
        #expect(DataSettings.share(defaults) == true)
        #expect(DataSettings.saveHistory(nil) == true && DataSettings.share(nil) == false)
    }

    @Test func reportWithSharingOffAsksFirstAndKeepsNothing() async {
        let (data, ui, services, defaults, _, recorder) = rig(share: false)
        recorder.append([Int16](repeating: 1, count: 32_000), sampleRate: 16_000, side: .theirs, endingAt: 102)
        ui.reportWrong(flagged(100.5...101.5))
        #expect(ui.feedbackDraft?.needsSharing == true)
        #expect(ui.feedbackDraft?.hasClip == true)
        await data.submit(expected: "Bến Thành")
        #expect(await services.feedback.items().isEmpty)
        ui.cancelFeedback()
        #expect(ui.feedbackDraft == nil)

        // Turning sharing on from the sheet, then sending, queues the line with its clip
        ui.reportWrong(flagged(100.5...101.5))
        ui.enableSharingForFeedback()
        #expect(ui.shareToImprove && DataSettings.share(defaults))
        #expect(ui.feedbackDraft?.needsSharing == false)
        await data.submit(expected: "  Bến Thành ")
        #expect(ui.feedbackDraft == nil)
        let items = services.feedbackItems
        #expect(items.count == 1)
        #expect(items.first?.heard == "Ben Thanh")
        #expect(items.first?.target == "Bến Thành")
        #expect(items.first?.expected == "Bến Thành")
        #expect(items.first?.mine == false)
        #expect(items.first?.languageCode == "en")
        #expect(items.first?.clipSeconds == 1.5)   // the range plus 0.25 s each side
    }

    @Test func correctionWithSharingOffIsIgnored() async {
        let (data, ui, services, _, _, recorder) = rig(share: false)
        defer { withExtendedLifetime(data) {} }
        recorder.append([Int16](repeating: 1, count: 32_000), sampleRate: 16_000, side: .theirs, endingAt: 102)
        ui.recordCorrection(flagged(100.5...101.5), "Ben Thanh market")
        await data.pendingWork()
        #expect(await services.feedback.items().isEmpty)
        #expect(ui.feedbackDraft == nil, "Sửa never opens the report sheet")
    }

    @Test func correctionWithSharingOnQueuesTheLineWithItsClip() async {
        let (data, ui, services, _, _, recorder) = rig(share: true)
        defer { withExtendedLifetime(data) {} }
        recorder.append([Int16](repeating: 1, count: 32_000), sampleRate: 16_000, side: .theirs, endingAt: 102)
        ui.recordCorrection(flagged(100.5...101.5), " Chợ Bến Thành ")
        await data.pendingWork()
        let items = services.feedbackItems
        #expect(items.count == 1)
        #expect(items.first?.lineID == "t-1")
        #expect(items.first?.heard == "Ben Thanh")
        #expect(items.first?.target == "Bến Thành", "the translation as it was")
        #expect(items.first?.correctedTranslation == "Chợ Bến Thành")
        #expect(items.first?.expected == "")
        #expect(items.first?.clipSeconds == 1.5)
        #expect(items.first?.languageCode == "en")

        // A second "Sửa" on the same line updates the queued item instead of adding one
        ui.recordCorrection(flagged(100.5...101.5), "Chợ Bến Thành (Q1)")
        await data.pendingWork()
        #expect(services.feedbackItems.count == 1)
        #expect(services.feedbackItems.first?.correctedTranslation == "Chợ Bến Thành (Q1)")
    }

    @Test func correctionAfterReportIsStoredOnTheReportedItem() async {
        let (data, ui, services, _, _, _) = rig(share: true)
        defer { withExtendedLifetime(data) {} }
        ui.reportWrong(flagged(nil))
        await data.submit(expected: "Bến Thành market")
        ui.recordCorrection(flagged(nil), "Chợ Bến Thành")
        await data.pendingWork()
        let items = services.feedbackItems
        #expect(items.count == 1)
        #expect(items.first?.expected == "Bến Thành market")
        #expect(items.first?.correctedTranslation == "Chợ Bến Thành")
    }

    @Test func sensitiveCorrectionIsQueuedUnselected() async {
        let (data, ui, services, _, _, _) = rig(share: true)
        defer { withExtendedLifetime(data) {} }
        var l = flagged(nil)
        l.source = "mật khẩu wifi"
        ui.recordCorrection(l, "the wifi password")
        await data.pendingWork()
        #expect(services.feedbackItems.first?.sensitive == true)
        #expect(services.feedbackItems.first?.selected == false)
    }

    @Test func reportWithoutAudioOrSensitive() async {
        let (data, ui, services, _, _, _) = rig(share: true)
        var l = flagged(nil)
        l.source = "mật khẩu hoa phay"
        l.mine = true
        ui.reportWrong(l)
        #expect(ui.feedbackDraft?.needsSharing == false)
        #expect(ui.feedbackDraft?.hasClip == false)
        await data.submit(expected: "")
        let item = services.feedbackItems.first
        #expect(item?.sensitive == true)
        #expect(item?.selected == false)
        #expect(item?.clipSeconds == nil)
    }
}

// MARK: Mic tap

@Suite(.serialized) struct MicPCMTapTests {
    private static func buffer(_ value: Int16, frames: Int = 1_600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.int16ChannelData![0][i] = value }
        return b
    }

    /// The audio thread reads `MicSource.tap` for every buffer: it is installed once and `connect` (every phone-only
    /// toggle, every "Giữ để nói" press) only moves the target and side under the tap's lock.
    @Test func connectNeverReassignsTheTap() throws {
        MicPCMTap.install()
        let installs = MicSource.tapInstallCount
        #expect(installs >= 1)
        #expect(MicSource.tap != nil)
        let c = ManualClock()
        let a = RingAudioClipRecorder(clock: c.clock), b = RingAudioClipRecorder(clock: c.clock)
        MicPCMTap.connect(a, side: .mine)
        MicPCMTap.connect(a, side: .theirs)
        MicPCMTap.connect(nil)
        MicPCMTap.connect(b, side: .mine)
        MicPCMTap.install()   // a second install is ignored
        #expect(MicSource.tapInstallCount == installs, "connect and later installs leave the tap alone")

        // Buffers go to the recorder and side connected now
        let tap = try #require(MicSource.tap)
        c.t = 101
        tap(Self.buffer(3))
        #expect(b.clip(100.9...101, side: .mine) != nil)
        #expect(a.clip(100.9...101, side: .mine) == nil && a.clip(100.9...101, side: .theirs) == nil)
        MicPCMTap.connect(b, side: .theirs)
        c.t = 102
        tap(Self.buffer(4))
        #expect(b.clip(101.9...102, side: .theirs) != nil)
        MicPCMTap.connect(nil)
        c.t = 103
        tap(Self.buffer(5))   // nothing connected: dropped
        #expect(b.clip(102.9...103, side: .theirs) == nil)
    }
}
