import AVFoundation
import Foundation

// Track C glue between the screen model and the data features: the persisted switches ("Lưu lịch sử", "Chia sẻ để
// cải thiện"), the "Báo dịch sai" flow (`UIState.reportWrong` → a draft → `FeedbackQueue`), the history mirror and
// the actions the History/Sharing screens call on `AppServices`. No SwiftUI here, so it is unit-tested.

/// The data switches in UserDefaults.
enum DataSettings {
    static let saveHistoryKey = "settings.saveHistory"
    static let shareKey = "settings.shareToImprove"

    /// Default on.
    static func saveHistory(_ d: UserDefaults?) -> Bool { d?.object(forKey: saveHistoryKey) as? Bool ?? true }
    /// Default off.
    static func share(_ d: UserDefaults?) -> Bool { d?.object(forKey: shareKey) as? Bool ?? false }
}

/// A "Báo dịch sai" report waiting in the sheet: the line, and whether sharing must be turned on first.
struct FeedbackDraft: Identifiable, Hashable, Sendable {
    var line: UILine
    /// "Chia sẻ để cải thiện" is off: the sheet asks to turn it on before anything is kept.
    var needsSharing: Bool
    /// An audio clip of the line was found in the recorder.
    var hasClip: Bool
    var id: String { line.id }
}

@MainActor
final class DataCoordinator {
    /// Recognizer ranges are tight: the clip keeps a little before and after.
    static let clipPadding: TimeInterval = 0.25

    let ui: UIState
    let services: AppServices
    private let defaults: UserDefaults?
    private let newID: () -> String
    private var pendingClip: Data?
    private(set) var history: HistoryRecorder?

    /// `defaults` nil: the switches are not persisted (demo mode, tests).
    init(ui: UIState, services: AppServices, defaults: UserDefaults?, newID: @escaping () -> String = { UUID().uuidString }) {
        self.ui = ui
        self.services = services
        self.defaults = defaults
        self.newID = newID
    }

    /// Loads the switches into `ui`, binds the intents and starts mirroring the transcript into history.
    func bind(observeHistory: Bool = true) {
        ui.saveHistory = DataSettings.saveHistory(defaults)
        ui.shareToImprove = DataSettings.share(defaults)
        ui.setSaveHistory = { [weak self] in self?.setSaveHistory($0) }
        ui.setShareToImprove = { [weak self] in self?.setShare($0) }
        ui.reportWrong = { [weak self] in self?.report($0) }
        ui.enableSharingForFeedback = { [weak self] in self?.enableSharingForDraft() }
        ui.submitFeedback = { [weak self] expected in
            guard let self else { return }
            Task { await self.submit(expected: expected) }
        }
        ui.cancelFeedback = { [weak self] in self?.cancel() }
        if ui.voiceName == nil { ui.voiceName = Self.systemVoiceName() }
        let store = services.history
        let on = ui.saveHistory
        Task { await store.setEnabled(on) }
        if observeHistory {
            let recorder = HistoryRecorder(store: store)
            history = recorder
            recorder.observe(ui)
        }
    }

    func setSaveHistory(_ on: Bool) {
        ui.saveHistory = on
        defaults?.set(on, forKey: DataSettings.saveHistoryKey)
        let store = services.history
        Task { await store.setEnabled(on) }
    }

    func setShare(_ on: Bool) {
        ui.shareToImprove = on
        defaults?.set(on, forKey: DataSettings.shareKey)
    }

    /// "Báo dịch sai" on `line`: the clip is taken now (the ring keeps only 20 s), held in memory, and kept only if
    /// the user sends the report with sharing on.
    func report(_ line: UILine) {
        pendingClip = line.audioRange.flatMap { r in
            services.recorder.clip((r.lowerBound - Self.clipPadding)...(r.upperBound + Self.clipPadding), side: line.side)
        }
        ui.feedbackDraft = FeedbackDraft(line: line, needsSharing: !ui.shareToImprove, hasClip: pendingClip != nil)
    }

    func enableSharingForDraft() {
        setShare(true)
        ui.feedbackDraft?.needsSharing = false
    }

    /// Queues the draft with the corrected text (may be empty). Nothing is kept while sharing is off.
    func submit(expected: String) async {
        guard let draft = ui.feedbackDraft, ui.shareToImprove else { return }
        let line = draft.line
        let fixed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let sensitive = FeedbackItem.looksSensitive(line.source, line.target, fixed)
        let clip = pendingClip
        let item = FeedbackItem(id: newID(), mine: line.mine, heard: line.source, expected: fixed,
                                clipSeconds: clip.flatMap(WAV.duration), clipFile: nil, sensitive: sensitive,
                                selected: !sensitive, at: line.at, target: line.target,
                                languageCode: ui.languageCode ?? "")
        ui.feedbackDraft = nil
        pendingClip = nil
        await services.feedback.add(item, clip: clip)
        services.feedbackItems = await services.feedback.items()
    }

    func cancel() {
        ui.feedbackDraft = nil
        pendingClip = nil
    }

    /// The Vietnamese voice the speaker uses (the same pick as `Speaker`); nil when the device has none.
    static func systemVoiceName(language: String = "vi-VN") -> String? {
        (EngineMapping.bestVoice(language) ?? AVSpeechSynthesisVoice(language: language))?.name
    }
}

// MARK: Screen actions

extension AppServices {
    func deleteHistory(_ id: String) async {
        await history.delete(sessionID: id)
        historySessions = await history.sessions()
    }

    func deleteAllHistory() async {
        await history.deleteAll()
        historySessions = await history.sessions()
    }

    func toggleFeedback(_ item: FeedbackItem) async {
        await feedback.setSelected(item.id, !item.selected)
        feedbackItems = await feedback.items()
    }

    /// Builds the export folder of the selected items; nil when none is selected or the export failed.
    func exportFeedback() async -> URL? {
        do {
            let url = try await feedback.exportBundle()
            feedbackItems = await feedback.items()
            return url
        } catch {
            Diag.log("feedback: export failed: \(error)")
            return nil
        }
    }

    func removeSentFeedback() async {
        await feedback.removeSent()
        feedbackItems = await feedback.items()
    }

    func removeAllFeedback() async {
        await feedback.removeAll()
        feedbackItems = await feedback.items()
    }
}
