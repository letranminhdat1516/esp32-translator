import Foundation

// The canvas sample data for demo mode (`-demo <screen>`). Sample conversation content, not UI copy, so it lives
// here rather than in shared/copy (CopyTests skips this file for the no-Vietnamese-literal rule).

@MainActor
enum DemoData {
    /// Saturday 15 November 2025 (the canvas date), 14:21 local time: the canvas' clock.
    static let now: Date = at(day: 15, 14, 21)

    static func at(day: Int, _ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2025, 11, day, hour, minute, second)
        return Calendar.current.date(from: c) ?? Date()
    }

    static let packs: [LanguagePack] = [
        LanguagePack(code: "en", appleLocale: "en-US", label: "English", labelLatin: "English", script: .latin),
        LanguagePack(code: "ko", appleLocale: "ko-KR", label: "한국어", labelLatin: "Korean", script: .hangul),
        LanguagePack(code: "ja", appleLocale: "ja-JP", label: "日本語", labelLatin: "Japanese", script: .cjk),
        LanguagePack(code: "zh", appleLocale: "zh-CN", label: "中文（简体）", labelLatin: "Chinese", script: .cjk),
        LanguagePack(code: "fr", appleLocale: "fr-FR", label: "Français", labelLatin: "French", script: .latin),
        LanguagePack(code: "th", appleLocale: "th-TH", label: "ไทย", labelLatin: "Thai", script: .thai),
    ]

    static let lines: [UILine] = [
        UILine(id: "d1", mine: false, source: "Hi, how much is the room per night?",
               target: "Chào bạn, phòng bao nhiêu một đêm?", at: at(day: 15, 14, 20, second: 5)),
        UILine(id: "d2", mine: true, source: "Tám trăm nghìn, có ăn sáng nhé.",
               target: "800,000 dong, breakfast included.", at: at(day: 15, 14, 20, second: 30)),
        UILine(id: "d3", mine: false, source: "Can I pay by card at Ben Thanh?",
               target: "Tôi trả bằng thẻ ở Bến Thành được không?", at: at(day: 15, 14, 21, second: 2)),
    ]

    static let history: [HistorySession] = [
        session("h1", at(day: 15, 14, 20), "en", "Chào bạn, phòng bao nhiêu một đêm?", 14),
        session("h2", at(day: 15, 9, 5), "en", "Cho tôi ra sân bay Tân Sơn Nhất.", 6),
        session("h3", at(day: 13, 19, 40), "ja", "Món này có cay không?", 22),
        session("h4", at(day: 13, 10, 12), "en", "Tôi bị ho ba ngày nay rồi.", 9),
    ]

    private static func session(_ id: String, _ start: Date, _ lang: String, _ first: String, _ count: Int) -> HistorySession {
        HistorySession(id: id, startedAt: start, languageCode: lang,
                       lines: [HistoryLine(mine: true, source: first, target: "", at: start)], lineCount: count)
    }

    static let glossary: [Term] = [
        Term(id: "g1", text: "Bến Thành"),
        Term(id: "g2", text: "bánh xèo", fixed: ["en": "Vietnamese pancake"]),
        Term(id: "g3", text: "Grab"),
        Term(id: "g4", text: "Zalo"),
        Term(id: "g5", text: "Tân Sơn Nhất"),
        Term(id: "g6", text: "Hồ Gươm"),
    ]

    static let glossaryDraft = "Phở Thìn Lò Đúc"

    static let feedback: [FeedbackItem] = [
        FeedbackItem(id: "f1", mine: true, heard: "a mốc xi xi lin", expected: "amoxicillin", clipSeconds: 3,
                     clipFile: "01.wav", at: at(day: 15, 10, 2)),
        FeedbackItem(id: "f2", mine: false, heard: "Ben Thanh", expected: "Bến Thành", clipSeconds: 2,
                     clipFile: "02.wav", at: at(day: 15, 14, 21)),
        FeedbackItem(id: "f3", mine: true, heard: "mật khẩu hoa phay", expected: "Wi-Fi", clipSeconds: 4,
                     clipFile: "03.wav", sensitive: true, selected: false, at: at(day: 15, 14, 30)),
    ]

    static let activityInfo = TranslatorActivityStatic(languageCode: "en", languageName: "tiếng Anh")
    static let activityState = TranslatorActivityState(listening: true, boardBattery: 88,
                                                       theirs: "Can I pay by card at Ben Thanh?",
                                                       translation: "Tôi trả bằng thẻ ở Bến Thành được không?", micOn: true)

    /// Fills the screen model and the services with the canvas data for `screen`, and binds the intents to local
    /// toggles so the demo can be clicked through.
    static func seed(_ screen: DemoScreen, ui: UIState, services: AppServices) {
        ui.session = .running("en")
        ui.offeredPacks = packs
        ui.languageNames = Dictionary(uniqueKeysWithValues: packs.map { ($0.code, $0.label) }).merging(["vi": "Tiếng Việt"]) { a, _ in a }
        ui.languageCode = "en"
        ui.languageLabel = "English"
        ui.packStatus = ["en": .installed, "ko": .downloading(0.64), "ja": .notDownloaded(megabytes: 310),
                         "zh": .notDownloaded(megabytes: 290), "fr": .notDownloaded(megabytes: 240), "th": .unsupported]
        ui.board = .ready
        ui.boardBattery = 88
        ui.boardCharging = true
        ui.boardMicOn = true
        ui.voiceName = "Linh"
        ui.listening = true
        ui.lines = lines
        services.partials.mine = "Được chứ, mình có máy quẹt…"
        ui.boardSubtitle = "Of course, we have a card reader…"
        ui.glossaryTerms = glossary
        ui.saveHistory = true
        ui.shareToImprove = false

        services.now = { now }
        services.historySessions = history
        services.feedbackItems = feedback
        services.activity = (activityInfo, activityState)
        services.selectedLineID = "d3"
        services.glossaryDraft = glossaryDraft
        services.permissions = PermissionsSnapshot(microphone: .granted, bluetooth: .notDetermined, speech: .notDetermined)
        if let pairing = services.pairing as? FakePairingModel {
            pairing.state = .confirming(name: "ESP-Translator", battery: 88)
        }
        services.level.push(0.9, at: .distantFuture)

        switch screen {
        case .phoneonly:
            ui.lines = Array(lines.prefix(2))
            services.partials.mine = ""
            ui.boardSubtitle = lines[1].target
            ui.board = .off
            ui.phoneOnly = true
        case .boardlost:
            ui.board = .scanning
            ui.boardLostAt = now.addingTimeInterval(-12)
            ui.boardLostBattery = 41
        case .sharing:
            ui.shareToImprove = true
        default:
            break
        }

        ui.startStop = { ui.listening.toggle() }
        ui.toggleBoardMic = { ui.boardMicOn.toggle() }
        ui.pickLanguage = { code in
            ui.languageCode = code
            ui.languageLabel = ui.languageNames[code] ?? code
        }
        ui.clear = {
            ui.lines.removeAll()
            services.partials.theirs = ""
            services.partials.mine = ""
        }
        ui.setSaveHistory = { ui.saveHistory = $0 }
        ui.setShareToImprove = { ui.shareToImprove = $0 }
        ui.setRefineTranslations = { ui.refineTranslations = $0 }
        ui.glossaryAdd = { text in
            ui.glossaryTerms.append(Term(id: UUID().uuidString, text: text))
        }
        ui.glossaryUpdate = { id, text in
            if let i = ui.glossaryTerms.firstIndex(where: { $0.id == id }) { ui.glossaryTerms[i].text = text }
        }
        ui.glossaryDelete = { id in ui.glossaryTerms.removeAll { $0.id == id } }
        ui.editLine = { line, text in
            if let i = ui.lines.firstIndex(where: { $0.id == line.id }) { ui.lines[i].target = text }
        }
        ui.holdToTalk = { ui.talkHeld = $0 }
        ui.glossaryAddFixed = { text, fixed in
            ui.glossaryTerms.append(Term(id: UUID().uuidString, text: text, fixed: [ui.languageCode ?? "en": fixed]))
        }
    }
}
