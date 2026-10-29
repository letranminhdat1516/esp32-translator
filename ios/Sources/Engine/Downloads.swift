import Foundation
import os

/// `downloadItem(item)` for every kind of missing item, reported on the `download` stream (R3): progress 0 when it
/// starts, progress updates, then done; or done with the error when it fails or is cancelled, and the call
/// throws `downloadFailed`. A cancelled system sheet is a failure, never "done" (the Swift app's 3f23288 bug).
///
/// - translation: Apple's download sheet for the pair's model (`prepareTranslation` in a hidden SwiftUI host)
/// - speechModel: the recognizer's assets from AssetInventory, with progress
/// - ttsVoice: iOS cannot install a voice for an app; opens Settings and reports done, so the caller re-checks
///   `missing(pair)` when the user comes back
@MainActor
final class Downloads {
    /// The work per kind, replaceable in tests. A `DownloadFailure` thrown here carries the reason shown to the user.
    struct Work {
        var translation: @MainActor (_ from: String, _ to: String) async throws -> Void
        var speech: @MainActor (_ language: String, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
        var voice: @MainActor () async throws -> Void
    }

    private let events: EngineEventSink
    private let work: Work
    private let onDone: @MainActor () -> Void

    /// `onDone` runs after every download, failed or not (the capabilities may have changed)
    init(events: EngineEventSink, work: Work, onDone: @escaping @MainActor () -> Void) {
        self.events = events
        self.work = work
        self.onDone = onDone
    }

    func download(_ item: MissingMsg) async throws {
        let events = self.events
        let reported = OSAllocatedUnfairLock(initialState: 0.0)
        events.send(.download(DownloadMsg(item: item, progress: 0, done: false)))
        do {
            switch item.kind {
            case .translation:
                // missing(pair) always names both sides; the engine has no home language of its own to guess
                guard let from = item.from else { throw DownloadFailure("translation item without a source language") }
                try await work.translation(from, item.to ?? item.language)
            case .speechModel:
                try await work.speech(item.language) { p in
                    // Progress fires often; one event per percent is enough
                    let send = reported.withLock { last in
                        guard p < 1, p - last >= 0.01 else { return false }
                        last = p
                        return true
                    }
                    if send { events.send(.download(DownloadMsg(item: item, progress: p, done: false))) }
                }
            case .ttsVoice:
                try await work.voice()
            }
        } catch {
            let message = String(describing: error)
            Diag.log("download \(item) failed: \(message)")
            onDone()
            events.send(.download(DownloadMsg(item: item, progress: reported.withLock { $0 }, done: true,
                                              error: message)))
            throw EngineErrors.downloadFailed(message)
        }
        Diag.log("download \(item) done")
        onDone()
        events.send(.download(DownloadMsg(item: item, progress: 1, done: true)))
    }
}
