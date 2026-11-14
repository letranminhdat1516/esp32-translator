// Shared pieces of the latency harness: clock, test timeline, event log, statistics, output.
import AVFAudio
import Foundation
import Speech
import Translation

let env = ProcessInfo.processInfo.environment
func envFlag(_ name: String, _ def: Bool) -> Bool { env[name].map { $0 != "0" } ?? def }

// MARK: Clock

private let processStart = DispatchTime.now().uptimeNanoseconds
/// Monotonic seconds since the process started
func now() -> Double {
    let origin = processStart  // lazy global: initialize it before reading the clock
    return Double(DispatchTime.now().uptimeNanoseconds - origin) / 1e9
}

/// Report lines go to stderr; stdout is redirected to a log for the app's Diag lines
func report(_ s: String = "") { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Sends the app's Diag output (one line per recognizer result) to a file instead of the terminal
func redirectDiag(to path: String) {
    freopen(path, "w", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
}

// MARK: Timeline

let sampleRate = 16_000.0

struct Utterance {
    let index: Int
    let text: String
    /// Speech start and end on the timeline, seconds (from the energy of the generated clip)
    let start: Double
    let end: Double
}

struct Timeline {
    /// Mono float samples at 16 kHz: lead silence, then each phrase followed by `gap` of silence
    let samples: [Float]
    let utterances: [Utterance]
    var duration: Double { Double(samples.count) / sampleRate }
}

func readMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: src)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    if src.format.sampleRate == sampleRate && src.format.channelCount == 1 && src.format.commonFormat == .pcmFormatFloat32 {
        return Array(UnsafeBufferPointer(start: src.floatChannelData![0], count: Int(src.frameLength)))
    }
    let conv = AVAudioConverter(from: src.format, to: target)!
    let out = AVAudioPCMBuffer(pcmFormat: target,
                               frameCapacity: AVAudioFrameCount(Double(src.frameLength) * sampleRate / src.format.sampleRate) + 64)!
    var given = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return src
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

/// First and last 10 ms frame above max(-50 dBFS, peak - 40 dB): where the synthetic voice really speaks
func speechRegion(_ x: [Float]) -> (Int, Int) {
    let hop = Int(sampleRate / 100)
    var levels: [Float] = []
    var i = 0
    while i + hop <= x.count {
        var s: Float = 0
        for j in i..<(i + hop) { s += x[j] * x[j] }
        levels.append(10 * log10(s / Float(hop) + 1e-12))
        i += hop
    }
    let peak = levels.max() ?? -120
    let threshold = max(-50, peak - 40)
    let first = levels.firstIndex { $0 > threshold } ?? 0
    let last = levels.lastIndex { $0 > threshold } ?? (levels.count - 1)
    return (first * hop, min(x.count, (last + 1) * hop))
}

/// Reads `list.tsv` (file \t reference text, paths relative to the list) and lays the phrases out: `lead`
/// seconds of silence, then each phrase trimmed to its speech followed by `gap` seconds of silence. A faint
/// noise floor (-65 dBFS, NOISE_DB) is added everywhere so the gates see a background like a real mic (not digital zero).
func buildTimeline(list: String, lead: Double = 1.5, gap: Double = 1.5, tail: Double = 3) throws -> Timeline {
    let listURL = URL(fileURLWithPath: list)
    let dir = listURL.deletingLastPathComponent()
    let lines = try String(contentsOf: listURL, encoding: .utf8).split(separator: "\n").map(String.init)
    var samples = [Float](repeating: 0, count: Int(lead * sampleRate))
    var utts: [Utterance] = []
    for (n, line) in lines.enumerated() where !line.isEmpty {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let url = parts[0].hasPrefix("/") ? URL(fileURLWithPath: parts[0]) : dir.appendingPathComponent(parts[0])
        let clip = try readMono16k(url)
        let (a, b) = speechRegion(clip)
        let start = Double(samples.count) / sampleRate
        samples.append(contentsOf: clip[a..<b])
        let end = Double(samples.count) / sampleRate
        utts.append(Utterance(index: n + 1, text: parts[1], start: start, end: end))
        samples.append(contentsOf: [Float](repeating: 0, count: Int(gap * sampleRate)))
    }
    samples.append(contentsOf: [Float](repeating: 0, count: Int(tail * sampleRate)))
    var rng = SystemRandomNumberGenerator()
    // NOISE_DB: RMS of the added white noise in dBFS (default -65), "off" for digital silence
    if env["NOISE_DB"] != "off" {
        let db = env["NOISE_DB"].flatMap(Float.init) ?? -65
        let noise = powf(10, db / 20) * 3.0.squareRoot().asFloat  // uniform in ±a has RMS a/√3
        for i in samples.indices { samples[i] += Float.random(in: -noise...noise, using: &rng) }
    }
    return Timeline(samples: samples, utterances: utts)
}

// MARK: Event log (thread safe)

final class Log<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, T)] = []
    func add(_ t: Double, _ x: T) { lock.lock(); items.append((t, x)); lock.unlock() }
    var all: [(Double, T)] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: Text matching (which utterance a final belongs to)

func words(_ s: String) -> [String] {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// The utterance a result arriving at `t` with `text` belongs to: among the last three utterances that had
/// started by then, the one sharing the most words (latest on a tie)
func attribute(_ text: String, at t: Double, _ utts: [Utterance]) -> Int? {
    let started = utts.filter { $0.start <= t }
    guard !started.isEmpty else { return nil }
    let w = Set(words(text))
    var best: (Int, Double)?
    for u in started.suffix(3) {
        let ref = Set(words(u.text))
        let score = w.isEmpty ? 0 : Double(w.intersection(ref).count) / Double(w.count)
        if best == nil || score >= best!.1 { best = (u.index, score) }
    }
    return best?.0
}

// MARK: Statistics and output

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.filter { $0.isFinite }.sorted()
    guard !s.isEmpty else { return .nan }
    let r = p * Double(s.count - 1)
    let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
}

func ms(_ x: Double) -> String { x.isFinite ? String(format: "%.0f", x * 1000) : "-" }

/// One row per metric: n, p50, p90, max in milliseconds
func summaryTable(_ title: String, _ metrics: [(String, [Double])]) -> String {
    var s = "\n== \(title)\n"
    s += "metric".padding(toLength: 52, withPad: " ", startingAt: 0) + "    n     p50     p90     max  (ms)\n"
    for (name, xs) in metrics {
        let v = xs.filter { $0.isFinite }
        let cols = [String(v.count), ms(percentile(v, 0.5)), ms(percentile(v, 0.9)), ms(v.max() ?? .nan)]
        s += name.padding(toLength: 52, withPad: " ", startingAt: 0)
            + cols.map { String(repeating: " ", count: max(0, 7 - $0.count)) + $0 }.joined(separator: " ") + "\n"
    }
    return s
}

final class TSV {
    private let handle: FileHandle
    init(_ path: String, header: [String]) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        write(header)
    }
    func write(_ cols: [String]) {
        let clean = cols.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        handle.write((clean.joined(separator: "\t") + "\n").data(using: .utf8)!)
    }
    func close() { try? handle.close() }
}

func sleepUntil(_ t: Double) async {
    let due = t - now()
    if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
}

// MARK: Assets

/// Reports whether the speech model, the translation models and the vi-VN voice are on this Mac. Never downloads.
func checkAssets() async -> (speechEN: Bool, dictationVI: Bool, enVI: Bool, viEN: Bool) {
    let st = await SpeechTranscriber.installedLocales.map(\.identifier)
    let dt = await DictationTranscriber.installedLocales.map(\.identifier)
    let enModule = LiveTranscriber(locale: Locale(identifier: "en-US"), engine: .speech)
    let viModule = LiveTranscriber(locale: Locale(identifier: "vi-VN"), engine: .dictation)
    let la = LanguageAvailability()
    let enVI = await la.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "vi"))
    let viEN = await la.status(from: Locale.Language(identifier: "vi"), to: Locale.Language(identifier: "en"))
    // AssetInventory.status says "supported" until this process reserves the locale (as the app does through
    // installAssetsIfNeeded); reserve only when the model is already on the Mac, so nothing is downloaded
    if st.contains("en_US") { try? await enModule.installAssetsIfNeeded() }
    if dt.contains("vi_VN") { try? await viModule.installAssetsIfNeeded() }
    let enStatus = await enModule.assetStatus
    let viStatus = await viModule.assetStatus
    report("assets: SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable) installed en_US=\(st.contains("en_US")) status(app module)=\(enStatus)")
    report("        DictationTranscriber installed vi_VN=\(dt.contains("vi_VN")) status(app module)=\(viStatus)")
    report("        Translation en→vi=\(enVI) vi→en=\(viEN)")
    let voice = EngineMapping.bestVoice("vi-VN")
    report("        vi-VN voice: \(voice.map { "\($0.name) quality=\($0.quality.rawValue) \($0.identifier)" } ?? "MISSING")")
    return (enStatus == .installed, viStatus == .installed, enVI == .installed, viEN == .installed)
}

extension Double { var asFloat: Float { Float(self) } }
