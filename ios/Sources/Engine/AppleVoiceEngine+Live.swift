import AVFAudio
import Foundation
import UIKit

// The engine on the iPhone's frameworks. iOS only (AVAudioSession, UIKit); the Mac tests build AppleVoiceEngine
// with fakes instead (ios/Tests/EngineTests).

extension Speaker: EngineSpeaker {}
extension MicSource: EngineMic {}

extension AppleVoiceEngine {
    static func live() -> AppleVoiceEngine {
        AppleVoiceEngine(platform: AppleEnginePlatform(
            session: AudioSession(),
            makeSpeaker: { Speaker(language: $0) },
            makeMic: { format, gate, sink, onSpeechStart, onSpeechEnd in
                MicSource(target: format, gate: gate, sink: sink, onSpeechStart: onSpeechStart,
                          onSpeechEnd: onSpeechEnd)
            },
            micPermitted: { AVAudioApplication.shared.recordPermission == .granted },
            requestMicPermission: { _ = await AVAudioApplication.requestRecordPermission() },
            recognizer: { await LiveTranscriber.resolve($0) },
            makeTranslator: { from, to in
                let translator = Translator(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
                return { try await translator.translate($0) }
            },
            downloads: .live,
            openSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            },
            gatherCapabilities: { await CapabilitiesAssembly.gather(home: $0) },
            gatherMissing: { await MissingAssembly.gather($0) }))
    }
}
