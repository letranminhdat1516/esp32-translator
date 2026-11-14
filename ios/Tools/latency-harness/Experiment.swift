// Harness-only experiments around the app's recognizer and gate (no app sources changed).
//
// ExpTranscriber mirrors LiveTranscriber's SpeechTranscriber setup and session (same module options, same
// analyzer options) but lets an experiment drop .fastResults and finalize through a given audio time instead of
// nil. A control run (REC=exp, FINALIZE_AT=nil, FAST=1) must behave like the app's LiveTranscriber.
import AVFAudio
import CoreMedia
import Foundation
import os
import Speech

/// What ThemRun needs from a recognizer: the app's LiveTranscriber or ExpTranscriber
protocol ThemRecognizer: AnyObject {
    var audioFormat: AVAudioFormat? { get }
    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Finalize through `through` seconds of fed audio, or everything (nil, as LiveTranscriber.finalizeNow)
    func finalize(through: Double?)
    /// Seconds of audio fed so far
    var audioFed: Double { get }
    func stop() async
}

extension LiveTranscriber: ThemRecognizer {
    var audioFed: Double { fed }
    func finalize(through: Double?) { finalizeNow() }  // the app's call: always through nil
}

final class ExpTranscriber: ThemRecognizer, @unchecked Sendable {
    private let module: SpeechTranscriber
    private(set) var audioFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let fed = OSAllocatedUnfairLock(initialState: 0.0)

    init(locale: Locale, fast: Bool) {
        module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                   reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
                                   attributeOptions: [.transcriptionConfidence])
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
                for try await r in module.results {
                    let s = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    onEvent(r.isFinal ? .final(s, confidence: nil) : .partial(s))
                }
            } catch {
                report("exp recognizer ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        fed.withLock { $0 += Double(buffer.frameLength) / buffer.format.sampleRate }
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    func finalize(through: Double?) {
        let time = through.map { CMTime(seconds: $0, preferredTimescale: 16_000) }
        Task { [analyzer] in try? await analyzer?.finalize(through: time) }
    }

    var audioFed: Double { fed.withLock { $0 } }

    func stop() async {
        input?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }
}

// MARK: Accuracy

/// Spoken forms of the numbers the recognizers write as digits in this script
private let numberWords: [String: String] = [
    "630": "six thirty", "6": "six", "30": "thirty", "10": "ten", "00": "", "20": "twenty", "15": "fifteen dollars",
    "11": "eleven",
]
private let viNumberWords: [String: String] = ["10": "mười"]

func normalizedWords(_ s: String, vietnamese: Bool) -> [String] {
    var out: [String] = []
    for w in words(s.replacingOccurrences(of: "$", with: " $ ")) {
        if let spoken = (vietnamese ? viNumberWords : numberWords)[w] {
            out += spoken.split(separator: " ").map(String.init)
        } else if w != "$" {
            out.append(w)
        }
    }
    // "$15" → "15 dollars" already spelled; drop a following duplicate "dollars"
    return out.enumerated().filter { i, w in !(w == "dollars" && i > 0 && out[i - 1] == "dollars") }.map(\.1)
}

/// Word error rate of `hyp` against `ref` (Levenshtein on words / reference length)
func wer(_ hyp: String, _ ref: String, vietnamese: Bool) -> Double {
    let h = normalizedWords(hyp, vietnamese: vietnamese), r = normalizedWords(ref, vietnamese: vietnamese)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + [Int](repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

/// The damage seen with finalize(through: nil): runs of punctuation in place of words (",......", "..").
/// An utterance is damaged when its text has such a run or its WER is above 0.3.
func isDamaged(_ text: String, ref: String, vietnamese: Bool) -> Bool {
    if text.range(of: #"[.,]\s*[.,]"#, options: .regularExpression) != nil { return true }
    return wer(text, ref, vietnamese: vietnamese) > 0.3
}
