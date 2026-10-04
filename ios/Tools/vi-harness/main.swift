// Vietnamese own-voice gate + recognizer harness (macOS command line).
//
// Runs the app's real code on recorded files: MicSource.handle (BufferConverter → VoiceGate → sink),
// LiveTranscriber (DictationTranscriber vi-VN with the app's options) and finalizeNow() on every gate end,
// exactly as ConversationEngine wires them. Build with ./build.sh, then:
//
//   RT=1 ./vi-harness <gate> <out.tsv> <events.jsonl> files…
//
// <gate>: new (VoiceGate), legacy (the energy gate shipped before), none (no gate), oracle (cut at the
// clean speech region read from a sibling .region file: [start, end] seconds), or seg-new / seg-legacy
// (gate only, no recognizer: prints the fed time ranges, fast).
// RT=1 paces the audio in real time (gated results are misleading when fed faster, see the spike report).
// GATE_OPEN, GATE_HOLD, GATE_VOICING, GATE_PCT, GATE_WIN, GATE_ONSET, GATE_ONSET_WIN, GATE_NEAR, GATE_HOLDNEAR,
// VoiceGate.Config. One gate runs across all files of a run, like one app session (GATE_PERSIST=0: per file).
// Output TSV: path \t finals joined \t seconds \t -1 \t "You say" lines (TurnAssembler, " | " between lines)
// \t translator input per final (VietnameseFixup) \t lines with the old assembly (for comparison).
import AVFAudio
import Foundation

let env = ProcessInfo.processInfo.environment

func gateConfig() -> VoiceGate.Config {
    var c = VoiceGate.Config()
    if let v = env["GATE_OPEN"].flatMap(Float.init) { c.openMarginDB = v }
    if let v = env["GATE_HOLD"].flatMap(Float.init) { c.holdMarginDB = v }
    if let v = env["GATE_VOICING"].flatMap(Float.init) { c.voicing = v }
    if let v = env["GATE_PCT"].flatMap(Double.init) { c.floorPercentile = v }
    if let v = env["GATE_WIN"].flatMap(Double.init) { c.floorWindow = v }
    if let v = env["GATE_ONSET"].flatMap(Int.init) { c.onsetFrames = v }
    if let v = env["GATE_ONSET_WIN"].flatMap(Double.init) { c.onsetWindow = v }
    if let v = env["GATE_NEAR"].flatMap(Float.init) { c.nearMarginDB = v }
    if let v = env["GATE_HOLDNEAR"].flatMap(Float.init) { c.holdNearMarginDB = v }
    if let v = env["GATE_RISE"].flatMap(Float.init) { c.maxRisePerUtterance = v }
    if let v = env["GATE_DECAYMAX"].flatMap(Float.init) { c.maxDecayDB = v }
    if let v = env["GATE_UPCT"].flatMap(Double.init) { c.userPercentile = v }
    if let v = env["GATE_SOFTGAP"].flatMap(Double.init) { c.softHoldGap = v }
    if let v = env["GATE_RELEARN"].flatMap(Float.init) { c.relearnMarginDB = v }
    return c
}

/// The mic tap delivers float buffers; 341 frames at 16 kHz is about the 21 ms the iPhone tap gives
let tapFrames: AVAudioFrameCount = 341

func readFile(_ path: String) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: b)
    return b
}

func slice(_ b: AVAudioPCMBuffer, _ from: Int, _ count: Int) -> AVAudioPCMBuffer {
    let n = max(0, min(count, Int(b.frameLength) - from))
    let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(max(n, 1)))!
    out.frameLength = AVAudioFrameCount(n)
    out.floatChannelData![0].update(from: b.floatChannelData![0] + from, count: n)
    return out
}

func readRegion(_ path: String) -> (Double, Double)? {
    let p = (path as NSString).deletingPathExtension + ".region"
    guard let d = FileManager.default.contents(atPath: p),
          let a = try? JSONSerialization.jsonObject(with: d) as? [Double], a.count == 2 else { return nil }
    return (a[0], a[1])
}

/// Feeds one file through a gate and calls `sink`/`ended`; returns fed ranges in input seconds
final class Router {
    let mode: String
    let sink: (AVAudioPCMBuffer) -> Void
    let ended: () -> Void
    /// One gate for the whole run, like the app's session (it learns the wearer's level); GATE_PERSIST=0 resets per file
    static var shared = VoiceGate(config: gateConfig())
    private let gate: VoiceGate
    private let legacy = LegacyVoiceGate()
    private var mic: MicSource?
    private var converter: BufferConverter?
    private(set) var ranges: [(Double, Double)] = []
    private var region: (Double, Double)?
    private var fed = 0.0

    init(mode: String, target: AVAudioFormat, region: (Double, Double)?,
         sink: @escaping (AVAudioPCMBuffer) -> Void, ended: @escaping () -> Void) {
        self.mode = mode
        self.sink = sink
        self.ended = ended
        self.region = region
        if env["GATE_PERSIST"] == "0" { Router.shared = VoiceGate(config: gateConfig()) }
        gate = Router.shared
        let counting: (AVAudioPCMBuffer) -> Void = { [unowned self] b in
            self.fed += Double(b.frameLength) / b.format.sampleRate
            sink(b)
        }
        if mode.hasSuffix("new") {
            mic = MicSource(target: target, gate: gate, sink: counting, onSpeechEnd: ended)
        } else {
            converter = BufferConverter(target: target)
        }
    }

    var gateStats: (Int, Int) { (gate.framesAnalyzed, gate.pitchAnalyses) }

    /// `t` = input time at the end of this buffer
    func handle(_ b: AVAudioPCMBuffer, t: Double) {
        let before = fed
        let dur = Double(b.frameLength) / b.format.sampleRate
        if let mic {
            mic.handle(b)
        } else if mode.hasSuffix("legacy") {
            // Old tap: gate the raw buffer, then convert
            switch legacy.process(b) {
            case .none: break
            case .audio(let bs): for x in bs { if let c = converter!.convert(x) { fed += Double(c.frameLength) / c.format.sampleRate; sink(c) } }
            case .ended: ended()
            }
        } else if mode == "oracle", let (s, e) = region {
            let lo = s - 0.3, hi = e + 0.8
            if t > lo && t - dur < hi, let c = converter!.convert(b) { fed += dur; sink(c) }
            if t >= hi && t - dur < hi { ended() }
        } else if let c = converter!.convert(b) {
            fed += dur
            sink(c)
        }
        let added = fed - before
        if added > 0 {
            let start = t - added
            if let last = ranges.last, abs(last.1 - start) < 0.03 { ranges[ranges.count - 1].1 = t } else { ranges.append((start, t)) }
        }
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Double, TranscriptEvent)] = []
    private let t0 = Date()
    func add(_ e: TranscriptEvent) { lock.lock(); events.append((Date().timeIntervalSince(t0), e)); lock.unlock() }
    var all: [(Double, TranscriptEvent)] { lock.lock(); defer { lock.unlock() }; return events }
    func now() -> Double { Date().timeIntervalSince(t0) }
}

func jsonString(_ s: String) -> String {
    let d = try! JSONSerialization.data(withJSONObject: [s], options: [])
    let a = String(data: d, encoding: .utf8)!
    return String(a.dropFirst().dropLast())
}

@main struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: vi-harness <new|legacy|none|oracle|seg-new|seg-legacy> <out.tsv> <events.jsonl> files…")
            exit(2)
        }
        let mode = args[1]
        let rt = env["RT"] == "1"
        FileManager.default.createFile(atPath: args[2], contents: nil)
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[2]))
        let evOut = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        let files = Array(args.dropFirst(4))

        if mode.hasPrefix("seg-") {
            // Gate only: fed ranges, CPU time
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            var cpu = 0.0, audio = 0.0, frames = 0, pitch = 0
            for path in files {
                let audioIn = try readFile(path)
                var ends: [Double] = []
                var t = 0.0
                let router = Router(mode: mode, target: target, region: nil, sink: { _ in }, ended: { ends.append(t) })
                let c0 = clock()
                var p = 0
                while p < Int(audioIn.frameLength) {
                    let b = slice(audioIn, p, Int(tapFrames))
                    p += Int(b.frameLength)
                    t = Double(p) / audioIn.format.sampleRate
                    router.handle(b, t: t)
                }
                cpu += Double(clock() - c0) / Double(CLOCKS_PER_SEC)
                audio += Double(audioIn.frameLength) / audioIn.format.sampleRate
                if env["GATE_PERSIST"] == "0" {
                    frames += router.gateStats.0
                    pitch += router.gateStats.1
                } else {
                    (frames, pitch) = router.gateStats  // one gate for the whole run: its counters are cumulative
                }
                let r = router.ranges.map { String(format: "%.2f:%.2f", $0.0, $0.1) }.joined(separator: ",")
                out.write("\(path)\t\(r)\t\(ends.map { String(format: "%.2f", $0) }.joined(separator: ","))\n".data(using: .utf8)!)
            }
            print(String(format: "gate CPU: %.3f s for %.0f s of audio = %.3f%% of one core; pitch analyses on %d of %d frames",
                         cpu, audio, 100 * cpu / audio, pitch, frames))
            try out.close()
            return
        }

        for path in files {
            let transcriber = LiveTranscriber(locale: Locale(identifier: "vi-VN"), engine: .dictation)
            if path == files.first { try await transcriber.installAssetsIfNeeded() }
            let collector = Collector()
            try await transcriber.start { collector.add($0) }
            guard let format = transcriber.audioFormat else { fatalError("no audio format") }
            let audioIn = try readFile(path)
            let router = Router(mode: mode, target: format, region: readRegion(path),
                                sink: { transcriber.feed($0) },
                                ended: { transcriber.finalizeNow() })
            let start = Date()
            var p = 0
            while p < Int(audioIn.frameLength) {
                let b = slice(audioIn, p, Int(tapFrames))
                p += Int(b.frameLength)
                router.handle(b, t: Double(p) / audioIn.format.sampleRate)
                if rt {
                    let due = Double(p) / audioIn.format.sampleRate - Date().timeIntervalSince(start)
                    if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
                }
            }
            // The user is silent after the file: whatever is still open gets finalized, as the gate would
            transcriber.finalizeNow()
            try await Task.sleep(nanoseconds: 2_500_000_000)
            await transcriber.stop()

            let events = collector.all
            var finals: [String] = []
            var lastPartial = ""
            for (_, e) in events {
                switch e {
                case .partial(let t): lastPartial = t
                case .final(let t, _): finals.append(t); lastPartial = ""
                }
            }
            var text = finals.filter { !$0.isEmpty }.joined(separator: " ")
            if !lastPartial.isEmpty { text += " ⟨V⟩" + lastPartial }
            let assembled = Harness.assemble(events)
            let line = [path, text, String(format: "%.2f", Date().timeIntervalSince(start)), "-1",
                        assembled.display, assembled.translationInput, assembled.legacy].joined(separator: "\t")
            out.write((line + "\n").data(using: .utf8)!)
            for (t, e) in events {
                let kind: String, s: String
                switch e {
                case .partial(let x): kind = "partial"; s = x
                case .final(let x, _): kind = "final"; s = x
                }
                evOut.write("{\"file\":\(jsonString(path)),\"t\":\(String(format: "%.3f", t)),\"kind\":\"\(kind)\",\"text\":\(jsonString(s))}\n".data(using: .utf8)!)
            }
            let r = router.ranges.map { String(format: "%.2f:%.2f", $0.0, $0.1) }.joined(separator: ",")
            evOut.write("{\"file\":\(jsonString(path)),\"fed\":\"\(r)\"}\n".data(using: .utf8)!)
            FileHandle.standardError.write("\(mode) \((path as NSString).lastPathComponent): \(text)\n".data(using: .utf8)!)
        }
        try out.close()
        try evOut.close()
    }
}
