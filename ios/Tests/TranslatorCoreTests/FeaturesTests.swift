import Foundation
import Testing
@testable import TranslatorCore

@MainActor @Suite struct FeaturesTests {
    @Test func levelModelThrottlesTo15Hz() {
        let m = LevelModel(interval: 0.066)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(m.push(0.5, at: t0))
        #expect(m.level == 0.5)
        #expect(!m.push(0.9, at: t0.addingTimeInterval(0.03)))
        #expect(m.level == 0.5)
        #expect(m.push(0.7, at: t0.addingTimeInterval(0.07)))
        #expect(m.level == 0.7)
        #expect(!m.push(0.1, at: t0.addingTimeInterval(0.08)))
        m.flush(at: t0.addingTimeInterval(0.09))
        #expect(m.level == 0.1)
        #expect(m.push(4, at: t0.addingTimeInterval(1)))
        #expect(m.level == 1)
    }

    @Test func uiLineSideAndAudioRange() {
        var l = UILine(id: "1", mine: true, source: "a", target: "b", at: Date())
        #expect(l.side == .mine)
        #expect(l.audioRange == nil)
        l.mine = false
        l.audioRange = 1.5...3
        #expect(l.side == .theirs)
        #expect(l.audioRange?.upperBound == 3)
    }

    @Test func historyFileName() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 5, 9, 3, 7)
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(from: c)!
        #expect(HistorySession.fileName(startedAt: d, languageCode: "ja", calendar: cal) == "20261105-090307-ja.json")
    }

    @Test func historyStoreAppendsAndSorts() async {
        let store = InMemoryHistoryStore()
        let t = Date(timeIntervalSince1970: 0)
        await store.append(HistoryLine(mine: false, source: "Hi", target: "Chào", at: t), sessionID: "a", languageCode: "en")
        await store.append(HistoryLine(mine: true, source: "Dạ", target: "Yes", at: t + 1), sessionID: "a", languageCode: "en")
        await store.append(HistoryLine(mine: true, source: "X", target: "Y", at: t + 100), sessionID: "b", languageCode: "ja")
        let s = await store.sessions()
        #expect(s.map(\.id) == ["b", "a"])
        #expect(s[1].lineCount == 2)
        #expect(s[1].title == "Chào")
        await store.delete(sessionID: "b")
        #expect(await store.sessions().count == 1)
        await store.deleteAll()
        #expect(await store.sessions().isEmpty)
    }

    @Test func historySectionsByDay() {
        let now = DemoData.now
        let sections = HistoryFormatting.sections(DemoData.history, now: now)
        #expect(sections.map(\.title) == ["Hôm nay", "Thứ Năm, 13/11"])
        #expect(sections[0].sessions.map { HistoryFormatting.time($0.startedAt) } == ["14:20", "09:05"])
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(HistoryFormatting.dayTitle(yesterday, now: now) == "Hôm qua")
        #expect(HistoryFormatting.longDate(now) == "Thứ Bảy, 15 tháng 11")
        #expect(HistoryFormatting.secondsAgo(now, now: now.addingTimeInterval(-5)) == 0)
    }

    @Test func feedbackQueue() async throws {
        let q = InMemoryFeedbackQueue(DemoData.feedback)
        #expect(InMemoryFeedbackQueue.selectedCount(await q.items()) == 2)
        await q.setSelected("f3", true)
        #expect(InMemoryFeedbackQueue.selectedCount(await q.items()) == 3)
        await q.removeAll()
        #expect(await q.items().isEmpty)
        #expect(try await q.exportBundle() == nil)
    }

    @Test func pairingFake() {
        let p = FakePairingModel()
        p.startScan()
        #expect(p.state == .scanning)
        p.state = .confirming(name: "ESP-Translator", battery: 88, code: "123456")
        p.confirm()
        #expect(p.state == .paired(name: "ESP-Translator"))
        p.reject()
        #expect(p.state == .idle)
    }

    @Test func activityStateIsTrimmedAndSmall() throws {
        let long = String(repeating: "á", count: 1000)
        let s = TranslatorActivityState(theirs: long, translation: long).trimmed()
        #expect(s.theirs.count == TranslatorActivityState.maxPhrase)
        #expect(s.theirs.hasSuffix("…"))
        #expect(try JSONEncoder().encode(s).count < 4096)
        let noop = NoopLiveActivityController()
        noop.start(languageCode: "en", languageName: "tiếng Anh", state: s)
        #expect(noop.lastState == s)
        noop.end()
        #expect(noop.lastState == nil)
    }

    @Test func permissionsSnapshot() {
        var p = PermissionsSnapshot(microphone: .granted)
        #expect(p.next == .bluetooth)
        #expect(!p.canContinue)
        p.bluetooth = .denied
        p.speech = .granted
        #expect(p.next == nil)
        #expect(p.canContinue)
    }

    @Test func languageRowStatus() {
        #expect(LanguageRowStatus.resolve(code: "en", explicit: .unsupported, session: nil, progress: nil) == .unsupported)
        #expect(LanguageRowStatus.resolve(code: "ja", explicit: nil, session: .downloading("ja"), progress: 0.4) == .downloading(0.4))
        #expect(LanguageRowStatus.resolve(code: "en", explicit: nil, session: .downloading("ja"), progress: 0.4) == .installed)
        #expect(LanguageRowStatus.resolve(code: "ja", explicit: nil, session: .needsDownload("ja", missing: []), progress: nil)
                == .notDownloaded(megabytes: nil))
    }

    @Test func transcriptShowsTheVietnameseSide() {
        let theirs = UILine(id: "1", mine: false, source: "Hi", target: "Chào", at: Date())
        let mine = UILine(id: "2", mine: true, source: "Dạ", target: "Yes", at: Date())
        let pending = UILine(id: "3", mine: false, source: "Hi", target: "", at: Date())
        #expect(TranscriptRowText.shown(theirs) == "Chào")
        #expect(TranscriptRowText.shown(mine) == "Dạ")
        #expect(TranscriptRowText.shown(pending) == "Hi")
    }
}
