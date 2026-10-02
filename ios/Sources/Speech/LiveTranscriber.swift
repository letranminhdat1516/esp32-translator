import AVFAudio
import Speech

enum TranscriptEvent: Sendable {
    /// Kết quả tạm, còn có thể đổi; mỗi lần thay thế toàn bộ phần tạm trước đó
    case partial(String)
    /// Đoạn đã chốt, không đổi nữa
    case final(String)
}

/// Nhận dạng giọng nói liên tục, chạy hoàn toàn trên máy bằng SpeechAnalyzer (iOS 26).
/// Analyzer chạy suốt phiên, không bật/tắt theo từng câu, để không mất thời gian khởi động lại model.
final class LiveTranscriber: @unchecked Sendable {
    enum Engine {
        /// Model mới, nhanh nhất; tiếng Anh dùng cái này
        case speech
        /// Model đọc chính tả; tiếng Việt chỉ có ở đây
        case dictation
    }

    let locale: Locale
    private(set) var audioFormat: AVAudioFormat?
    private let module: any SpeechModule
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, engine: Engine) {
        self.locale = locale
        switch engine {
        case .speech:
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults],
                                       attributeOptions: [])
        case .dictation:
            module = DictationTranscriber(locale: locale, contentHints: [],
                                          transcriptionOptions: [.punctuation],
                                          reportingOptions: [.volatileResults, .frequentFinalization],
                                          attributeOptions: [])
        }
    }

    /// Tải model nhận dạng nếu chưa có (một lần, sau đó dùng offline)
    func installAssetsIfNeeded() async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        audioFormat = format
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        input = continuation
        self.analyzer = analyzer

        resultsTask = Task { [module] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results {
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results {
                        onEvent(Self.event(text: r.text, isFinal: r.isFinal))
                    }
                }
            } catch {
                print("[\(self.locale.identifier)] results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// An toàn khi gọi từ luồng âm thanh hoặc hàng đợi BLE
    func feed(_ buffer: AVAudioPCMBuffer) {
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() async {
        input?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private static func event(text: AttributedString, isFinal: Bool) -> TranscriptEvent {
        let s = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return isFinal ? .final(s) : .partial(s)
    }
}
