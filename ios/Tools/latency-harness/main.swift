// Latency harness for the conversation pipeline (macOS command line, the app's own sources; see README.md).
//
//   ./latency-harness them <en/list.tsv> <out.tsv>    Them → You: board VAD/ADPCM → SpeechTranscriber → translate → TTS
//   ./latency-harness you  <vi/list.tsv> <out.tsv>    You → Them: VoiceGate → DictationTranscriber → SubtitleTranslator
//   ./latency-harness translate-bench <out.tsv>       first (cold) vs warm Translator calls, both directions
//   ./latency-harness tts-bench <out.tsv>             speak() → didStart and write() → first buffer, cold vs warm
//
// Audio is paced in real time; all times are wall clock, measured from the speech start/end of each phrase on
// the generated timeline. The app's Diag lines go to <out.tsv>.diag.log. Summary tables go to stderr.
import AVFAudio
import Foundation

@main struct Main {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            report("usage: latency-harness them|you <list.tsv> <out.tsv> | translate-bench <out.tsv> | tts-bench <out.tsv>")
            exit(2)
        }
        let mode = args[1]
        let out = args.last!
        redirectDiag(to: out + ".diag.log")
        let variant = env["VARIANT"] ?? "app"
        let assets = await checkAssets()

        switch mode {
        case "them":
            guard assets.speechEN else { report("SKIP them: SpeechTranscriber en-US model is not installed"); exit(3) }
            if !assets.enVI { report("WARNING: en→vi translation model not installed: translations will fail") }
            let tl = try buildTimeline(list: args[2])
            report(String(format: "them: %d phrases, %.1f s of audio, real time", tl.utterances.count, tl.duration))
            try await ThemRun(tl: tl, variant: variant).run(tsvPath: out)
        case "you":
            guard assets.dictationVI else { report("SKIP you: DictationTranscriber vi-VN model is not installed"); exit(3) }
            if !assets.viEN { report("WARNING: vi→en translation model not installed: translations will fail") }
            let tl = try buildTimeline(list: args[2])
            report(String(format: "you: %d phrases, %.1f s of audio, real time", tl.utterances.count, tl.duration))
            try await YouRun(tl: tl, variant: variant).run(tsvPath: out)
        case "translate-bench":
            try await translateBench(out)
        case "tts-bench":
            await ttsBench(out)
        default:
            report("unknown mode \(mode)")
            exit(2)
        }
    }
}

let enPhrases = [
    "Good evening, do you have a reservation?", "Where would you like to go?", "That will be fifteen dollars, please.",
    "How long have you had this pain?", "Take one tablet twice a day after meals.", "Would you like a bag for that?",
    "We accept cash and all major credit cards.", "Breakfast is served from six thirty to ten.",
    "It will take about twenty minutes because of the traffic.",
    "If you are allergic to any medicine, please tell me now, because the antibiotic I am going to prescribe can cause a reaction in some patients.",
    "Your room is on the fifth floor, the elevator is to the left.",
]
let viPhrases = [
    "Xin chào, tôi đã đặt phòng tên Nguyễn.", "Cho tôi hỏi mấy giờ trả phòng?", "Làm ơn chở tôi đến sân bay.",
    "Đi hết bao nhiêu tiền vậy?", "Tôi bị đau bụng từ tối hôm qua.", "Tôi bị dị ứng với thuốc kháng sinh.",
    "Cái áo này giá bao nhiêu?", "Có cỡ nhỏ hơn không?", "Tôi muốn trả bằng thẻ.", "Cảm ơn anh rất nhiều.",
    "Tôi cần đổi phòng vì máy lạnh trong phòng không hoạt động và tối qua tôi không ngủ được.",
]

/// The first call on a fresh Translator (as the app's lazily made one) vs the following calls
@MainActor func translateBench(_ out: String) async throws {
    let tsv = try TSV(out, header: ["pair", "call", "cold", "chars", "ms", "text", "translated"])
    var rows: [(String, [Double])] = []
    for (from, to, phrases) in [("en", "vi", enPhrases), ("vi", "en", viPhrases)] {
        let a = now()
        let tr = Translator(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        let make = now() - a
        var warm: [Double] = []
        var cold = Double.nan
        for (i, p) in phrases.enumerated() {
            let s = now()
            let r: String
            do { r = try await tr.translate(p) } catch { report("translate \(from)→\(to) failed: \(error)"); r = "ERROR" }
            let d = now() - s
            if i == 0 { cold = d } else { warm.append(d) }
            tsv.write(["\(from)>\(to)", String(i), i == 0 ? "1" : "0", String(p.count), ms(d), p, r])
        }
        // A second session for the same pair, once the models are loaded (what a pair switch back costs)
        let tr2 = Translator(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        let s = now()
        _ = try? await tr2.translate(phrases[1])
        let second = now() - s
        rows += [("\(from)→\(to) session init", [make]), ("\(from)→\(to) first call (cold)", [cold]),
                 ("\(from)→\(to) warm calls", warm), ("\(from)→\(to) first call, 2nd session (models loaded)", [second])]
    }
    tsv.close()
    report(summaryTable("Translation [\(Translator.strategy)]", rows))
}

/// speak() → didStart (played) and write() → first buffer (synthesis only); cold = first utterance of a fresh
/// synthesizer without warm-up, then with the app's warm-up, then warm
@MainActor func ttsBench(_ out: String) async {
    let tsv = try! TSV(out, header: ["mode", "case", "ms", "text"])
    var rows: [(String, [Double])] = []
    let volume = env["TTS_VOLUME"].flatMap(Float.init) ?? 1
    let sentences = ["Phòng của bạn ở tầng năm.", "Bạn muốn đi đâu?", "Mười lăm đô la.", "Bạn bị đau bao lâu rồi?",
                     "Uống một viên hai lần mỗi ngày sau bữa ăn.", "Chúng tôi nhận tiền mặt và thẻ tín dụng."]
    // Only the first mode of a process is really cold (the speech service keeps the voice loaded afterwards)
    let modes = (env["TTS_MODES"] ?? "write,speak").split(separator: ",").compactMap { TTSProbe.Mode(rawValue: String($0)) }
    for mode in modes {
        for warmUp in [false, true] {
            let tts = TTSProbe(mode: mode, volume: volume)
            if warmUp {
                tts.warmUp()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            var times: [Double] = []
            for (i, s) in sentences.enumerated() where warmUp || i == 0 {
                var started = Double.nan
                let call = now()
                let u = tts.speak(s) { started = $0 }
                await tts.waitFinished(u)
                try? await Task.sleep(nanoseconds: 50_000_000)
                times.append(started - call)
                let label = !warmUp ? "cold (no warm-up)" : i == 0 ? "first after warm-up" : "warm"
                tsv.write([mode.rawValue, label, ms(started - call), s])
            }
            if !warmUp { rows.append(("\(mode.rawValue): cold, no warm-up", times)) } else {
                rows.append(("\(mode.rawValue): first after warm-up", [times[0]]))
                rows.append(("\(mode.rawValue): warm", Array(times.dropFirst())))
            }
        }
    }
    tsv.close()
    let v = TTSProbe(mode: .write, volume: 1).voice
    report(summaryTable("TTS vi-VN [\(v?.name ?? "none") quality=\(v?.quality.rawValue ?? 0)] speak→didStart / write→first buffer", rows))
}
