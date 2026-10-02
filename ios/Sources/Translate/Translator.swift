import Foundation
import Translation

/// Dịch offline bằng model của Apple đã tải về máy.
actor Translator {
    private let session: TranslationSession

    init(from source: Locale.Language, to target: Locale.Language) {
        if #available(iOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
    }

    func translate(_ text: String) async throws -> String {
        try await session.translate(text).targetText
    }

    static func isInstalled(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) == .installed
    }
}

/// Chạy bản dịch mới nhất, bỏ các bản cũ đã lỗi thời.
/// Dùng cho phụ đề trực tiếp: chữ thay đổi liên tục, chỉ cần bản dịch của câu hiện tại.
@MainActor
final class LatestWinsTranslator {
    private let translator: Translator
    private let onResult: (String) -> Void
    private var running = false
    private var pending: String?

    init(translator: Translator, onResult: @escaping (String) -> Void) {
        self.translator = translator
        self.onResult = onResult
    }

    func submit(_ text: String) {
        pending = text
        guard !running else { return }
        running = true
        Task {
            while let next = pending {
                pending = nil
                if let out = try? await translator.translate(next) { onResult(out) }
            }
            running = false
        }
    }
}
