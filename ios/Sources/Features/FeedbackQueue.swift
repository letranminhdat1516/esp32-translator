import Foundation

/// One "Báo dịch sai" report: what was heard, what it should have been, and an optional audio clip.
struct FeedbackItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var mine: Bool
    /// What the recognizer produced ("a mốc xi xi lin").
    var heard: String
    /// What the user says it should be ("amoxicillin").
    var expected: String
    /// Length of the clip in seconds; nil without audio.
    var clipSeconds: Double?
    /// File name of the clip inside the queue folder (`NN.wav`).
    var clipFile: String?
    /// May contain a password or similar: not selected by default.
    var sensitive = false
    var selected = true
    var at: Date
}

/// The local queue of reports; export builds `feedback-<date>/` with `items.json` and the WAVs for the share
/// sheet. Track C implements the file-backed queue and the export bundle.
protocol FeedbackQueueing: Sendable {
    func items() async -> [FeedbackItem]
    func add(_ item: FeedbackItem, clip: Data?) async
    func setSelected(_ id: String, _ selected: Bool) async
    func removeAll() async
    /// The folder to share, or nil when nothing is selected.
    func exportBundle() async throws -> URL?
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
    func exportBundle() async throws -> URL? { nil }

    /// How many items an export would send (the "Gửi n câu" button).
    static func selectedCount(_ items: [FeedbackItem]) -> Int { items.filter(\.selected).count }
}
