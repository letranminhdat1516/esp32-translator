import Foundation
import SwiftUI
import Translation
import UIKit

extension Downloads.Work {
    /// The real downloads (computed: a stored static of a non-Sendable type is not concurrency safe)
    static var live: Downloads.Work { Downloads.Work(
        translation: { from, to in
            let source = Locale.Language(identifier: from), target = Locale.Language(identifier: to)
            let availability = LanguageAvailability()
            if await availability.status(from: source, to: target) == .installed { return }
            try await TranslationSheet.prepare(source: source, target: target)
            // The sheet can end without an error while nothing was installed: check, never assume
            guard await availability.status(from: source, to: target) == .installed else {
                throw DownloadFailure("the \(from)→\(to) model is not installed")
            }
        },
        speech: { language, progress in
            guard let recognizer = await LiveTranscriber.resolve(language) else {
                throw DownloadFailure("no on-device recognizer for \(language)")
            }
            try await recognizer.installAssets(progress: progress)
        },
        voice: {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await UIApplication.shared.open(url)
        }) }
}

/// Apple's translation download sheet needs a SwiftUI view: an invisible host is presented over the app
/// view, runs `prepareTranslation()` in `.translationTask` and goes away when it returns or throws
@MainActor
enum TranslationSheet {
    static func prepare(source: Locale.Language, target: Locale.Language) async throws {
        guard let presenter = topViewController() else {
            throw DownloadFailure("no window to show the download sheet")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var host: UIViewController?
            var finished = false
            let view = PrepareTranslationView(configuration: .init(source: source, target: target)) { result in
                guard !finished else { return }
                finished = true
                host?.dismiss(animated: false)
                host = nil
                continuation.resume(with: result)
            }
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .clear
            controller.modalPresentationStyle = .overFullScreen
            host = controller
            presenter.present(controller, animated: false)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

private struct PrepareTranslationView: View {
    let configuration: TranslationSession.Configuration
    let finish: @MainActor (Result<Void, Error>) -> Void

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .translationTask(configuration) { session in
                do {
                    try await Self.prepare(SessionHandle(session: session))
                    await MainActor.run { finish(.success(())) }
                } catch {
                    await MainActor.run { finish(.failure(error)) }
                }
            }
    }

    /// The session SwiftUI hands to this one task, used by this one call only (TranslationSession is not Sendable;
    /// the box lets the call leave the main actor without a data-race diagnostic)
    private struct SessionHandle: @unchecked Sendable {
        let session: TranslationSession
    }

    private nonisolated static func prepare(_ handle: SessionHandle) async throws {
        try await handle.session.prepareTranslation()
    }
}
