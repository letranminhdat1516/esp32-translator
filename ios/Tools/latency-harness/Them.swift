// Them → You, wired like AppleVoiceEngine.feedTheirAudio + ConversationController.handleTheirs/translateTheirs:
//   board VAD + ADPCM packets (20 ms, real time) → ADPCMDecoder → pcm16Buffer → BufferConverter →
//   LiveTranscriber(SpeechTranscriber en-US) with finalizeNow() 0.25 s after packets pause →
//   final phrase (> 1 char) → in-order worker: TextPipeline(.theirs) over Translator (en→vi) → TTS vi-VN.
// Experiments (harness only): PAD=silence|noise feeds 20 ms frames of digital silence or comfort noise at the
// board VAD's floor while packets pause (natural endpointing); BOARD_HANGOVER_MS (800); PAUSE_GAP (0.25 s);
// REC=exp uses ExpTranscriber with FAST=0|1 and FINALIZE_AT=nil|last (finalize through the last real audio).
// Env: ADPCM=1 (0: raw PCM), STREAM=vad|continuous (continuous: the board streams everything, no pause
// finalize unless FINALIZE=1 is set explicitly), FINALIZE=1 (0: no finalizeNow on pause), TTS=speak|write, TTS_VOLUME=1, WARMUP=1 (TTS warm-up).
import AVFAudio
import Foundation

private struct FinalRec {
    let t: Double
    let text: String
    var utt: Int?
    var translateStart = Double.nan, translateEnd = Double.nan
    var cold = false
    var translated = ""
    var speakCall = Double.nan, audioStart = Double.nan
}

@MainActor
final class ThemRun {
    let tl: Timeline
    let variant: String
    let adpcm = envFlag("ADPCM", true)
    let continuous = env["STREAM"] == "continuous"
    lazy var finalize = envFlag("FINALIZE", !continuous)
    let pad = env["PAD"] ?? "none"
    let pauseGap = env["PAUSE_GAP"].flatMap(Double.init) ?? 0.25
    let exp = env["REC"] == "exp"
    let fast = envFlag("FAST", true)
    let finalizeAtLast = env["FINALIZE_AT"] == "last"
    let tts: TTSProbe
    private var t0 = 0.0
    private func rel() -> Double { now() - t0 }

    private let events = Log<TranscriptEvent>()
    private var finals: [FinalRec] = []
    private var queue: [Int] = []
    private var worker: Task<Void, Never>?
    private var translator: Translator!
    private var translations = 0
    private let pipeline: TextPipeline
    private var finalizeCalls: [Double] = []
    private var vadStops: [Double] = []

    init(tl: Timeline, variant: String) throws {
        self.tl = tl
        self.variant = variant
        let mode = TTSProbe.Mode(rawValue: env["TTS"] ?? "speak") ?? .speak
        tts = TTSProbe(mode: mode, volume: env["TTS_VOLUME"].flatMap(Float.init) ?? 1)
        pipeline = try TextPipeline(home: SharedResources.languagePack("vi"), other: SharedResources.languagePack("en"))
    }

    func run(tsvPath: String) async throws {
        let x: ThemRecognizer = exp ? ExpTranscriber(locale: Locale(identifier: "en-US"), fast: fast)
                                    : LiveTranscriber(locale: Locale(identifier: "en-US"), engine: .speech)
        let log = events
        let startLocal = now()
        try await x.start { [weak self] e in
            guard let self else { return }
            let t = now()
            log.add(t, e)
            Task { @MainActor in self.onEvent(e, at: t) }
        }
        report(String(format: "them: SpeechTranscriber en-US started in %.0f ms (prepareToAnalyze + start)", (now() - startLocal) * 1000))
        guard let format = x.audioFormat else { fatalError("no audio format") }
        // As AppleVoiceEngine.start: the translator is made lazily on the first phrase (cold), the voice warmed up
        if envFlag("WARMUP", true) { tts.warmUp() }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let converter = BufferConverter(target: format)
        var vad = BoardVAD()
        var encoder = ADPCMEncoder()
        var decoder = ADPCMDecoder()
        var pause: DispatchWorkItem?
        let ints = tl.samples.map { Int16(max(-32768, min(32767, $0 * 32767))) }
        let frame = 320
        var wasSpeaking = false
        var lastRealAudio = 0.0, everSent = false
        t0 = now()
        var k = 0
        while (k + 1) * frame <= ints.count {
            let tEnd = Double((k + 1) * frame) / sampleRate
            await sleepUntil(t0 + tEnd)
            let f = Array(ints[(k * frame)..<((k + 1) * frame)])
            let voiced = vad.step(f)
            let send = continuous ? [f] : voiced
            if wasSpeaking && !vad.speaking { vadStops.append(rel()) }
            wasSpeaking = vad.speaking
            for pkt in send {
                let pcm = adpcm ? decoder.decode(encoder.packet(pkt[...])) : pkt
                guard let b = EngineMapping.pcm16Buffer(pcm, sampleRate: sampleRate), let c = converter.convert(b) else { continue }
                x.feed(c)
            }
            if !voiced.isEmpty { lastRealAudio = x.audioFed; everSent = true }
            // PAD: the app would fill the pause itself with silence or comfort noise until the next packet
            if send.isEmpty && everSent && pad != "none" {
                var filler = [Int16](repeating: 0, count: frame)
                if pad == "noise" {
                    let a = Float(32767) * powf(10, vad.floorDB / 20) * 3.0.squareRoot().asFloat
                    for i in filler.indices { filler[i] = Int16(Float.random(in: -a...a)) }
                }
                if let b = EngineMapping.pcm16Buffer(filler, sampleRate: sampleRate), let c = converter.convert(b) { x.feed(c) }
            }
            // AppleVoiceEngine.feedTheirAudio: finalize 0.25 s after the board's packets pause. With
            // STREAM=continuous the pause is where the board VAD would have stopped (audio keeps flowing).
            if finalize && !voiced.isEmpty {
                pause?.cancel()
                let through: Double? = finalizeAtLast ? lastRealAudio : nil
                let item = DispatchWorkItem { [weak self] in
                    x.finalize(through: through)
                    MainActor.assumeIsolated { self?.finalizeCalls.append(self!.rel()) }
                }
                pause = item
                DispatchQueue.main.asyncAfter(deadline: .now() + pauseGap, execute: item)
            }
            k += 1
        }
        // Let the last phrase's translation and speech finish
        let deadline = now() + 15
        while now() < deadline && (worker != nil || tts.busy > 0) { try await Task.sleep(nanoseconds: 100_000_000) }
        await x.stop()
        write(tsvPath)
    }

    private func onEvent(_ e: TranscriptEvent, at t: Double) {
        guard case .final(let text, _, _) = e, text.count > 1 else { return }
        var r = FinalRec(t: t - t0, text: text)
        r.utt = attribute(text, at: t - t0, tl.utterances)
        finals.append(r)
        queue.append(finals.count - 1)
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !queue.isEmpty {
                let i = queue.removeFirst()
                await translateAndSpeak(i)
            }
            worker = nil
        }
    }

    private func translateAndSpeak(_ i: Int) async {
        if translator == nil {
            translator = Translator(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "vi"))
        }
        let tr = translator!
        finals[i].cold = translations == 0
        translations += 1
        finals[i].translateStart = rel()
        let out = try? await pipeline.translate(finals[i].text, .theirs) { @Sendable in try await tr.translate($0) }
        finals[i].translateEnd = rel()
        guard let out, !out.isEmpty else { return }
        finals[i].translated = out
        finals[i].speakCall = rel()
        tts.speak(out) { [weak self] t in
            guard let self else { return }
            self.finals[i].audioStart = t - self.t0
        }
    }

    private func write(_ path: String) {
        let partials = events.all.compactMap { (t, e) -> Double? in
            if case .partial(let s, _) = e, !s.isEmpty { return t - t0 }
            return nil
        }
        let tsv = try! TSV(path, header: ["dir", "variant", "utt", "text", "speech_start", "speech_end",
                                          "first_volatile_from_start", "vad_stop_after_end", "finalize_call_after_end",
                                          "final_first_after_end", "final_last_after_end", "finalize_to_final",
                                          "n_finals", "recognized", "translate_ms_last", "translate_cold",
                                          "translated", "tts_first_audio_ms", "e2e_last_ms", "e2e_first_audio_after_end",
                                          "wer", "damaged"])
        var damaged = 0, splitsLong = 0, werSum = 0.0
        var m: [String: [Double]] = [:]
        func add(_ k: String, _ v: Double) { m[k, default: []].append(v) }
        for (n, u) in tl.utterances.enumerated() {
            let nextStart = n + 1 < tl.utterances.count ? tl.utterances[n + 1].start : .infinity
            let fv = partials.first { $0 >= u.start && $0 < nextStart }.map { $0 - u.start } ?? .nan
            let vs = vadStops.first { $0 >= u.end && $0 < nextStart }.map { $0 - u.end } ?? .nan
            let fc = finalizeCalls.first { $0 >= u.end && $0 < nextStart }
            let mine = finals.filter { $0.utt == u.index }
            let last = mine.last
            let ff = mine.first.map { $0.t - u.end } ?? .nan
            let fl = last.map { $0.t - u.end } ?? .nan
            let f2f = (last != nil && fc != nil) ? last!.t - fc! : .nan
            let trMs = last.map { $0.translateEnd - $0.translateStart } ?? .nan
            let ttsMs = last.map { $0.audioStart - $0.speakCall } ?? .nan
            let e2e = last.map { $0.audioStart - u.end } ?? .nan
            let e2eFirst = mine.first.map { $0.audioStart - u.end } ?? .nan
            add("t_first_volatile (from speech start)", fv)
            add("board VAD stop (after speech end)", vs)
            if let fc { add("finalizeNow call (after speech end)", fc - u.end) }
            add("t_final first phrase (after speech end)", ff)
            add("t_final last phrase (after speech end)", fl)
            if fc != nil { add("finalizeNow → final", f2f) }
            if last?.cold == true { add("t_translate COLD (first call)", trMs) } else { add("t_translate warm (final phrase)", trMs) }
            add("t_tts_first_audio (speak → audio)", ttsMs)
            add("E2E speech end → first TTS audio (last phrase)", e2e)
            add("first TTS audio of utterance (after speech end)", e2eFirst)
            let recognized = mine.map(\.text).joined(separator: " ")
            let w = wer(recognized, u.text, vietnamese: false)
            let bad = isDamaged(recognized, ref: u.text, vietnamese: false)
            werSum += w
            if bad { damaged += 1 }
            if u.text.count > 100 && mine.count > 1 { splitsLong += mine.count - 1 }
            tsv.write(["them", variant, String(u.index), u.text, String(format: "%.3f", u.start), String(format: "%.3f", u.end),
                       ms(fv), ms(vs), ms(fc.map { $0 - u.end } ?? .nan), ms(ff), ms(fl), ms(f2f), String(mine.count),
                       mine.map(\.text).joined(separator: " | "), ms(trMs), last?.cold == true ? "1" : "0",
                       mine.map(\.translated).joined(separator: " | "), ms(ttsMs), ms(e2e), ms(e2eFirst),
                       String(format: "%.2f", w), bad ? "1" : "0"])
        }
        tsv.close()
        let fl = m["t_final last phrase (after speech end)"] ?? [], e2e = m["E2E speech end → first TTS audio (last phrase)"] ?? []
        let ff = m["t_final first phrase (after speech end)"] ?? []
        report("RESULT\tthem\t\(variant)\tdamaged=\(damaged)/\(tl.utterances.count)\tsplits_long=\(splitsLong)\twer=\(String(format: "%.2f", werSum / Double(tl.utterances.count)))\tfinal_first_p50=\(ms(percentile(ff, 0.5)))\tfinal_last_p50=\(ms(percentile(fl, 0.5)))\tp90=\(ms(percentile(fl, 0.9)))\tn=\(fl.filter(\.isFinite).count)\te2e_p50=\(ms(percentile(e2e, 0.5)))\tp90=\(ms(percentile(e2e, 0.9)))")
        // Every phrase translation (not only the last of each utterance)
        let allTr = finals.filter { !$0.cold }.map { $0.translateEnd - $0.translateStart }
        let order = ["t_first_volatile (from speech start)", "board VAD stop (after speech end)",
                     "finalizeNow call (after speech end)", "t_final first phrase (after speech end)",
                     "t_final last phrase (after speech end)", "finalizeNow → final", "t_translate COLD (first call)",
                     "t_translate warm (final phrase)", "t_tts_first_audio (speak → audio)",
                     "first TTS audio of utterance (after speech end)", "E2E speech end → first TTS audio (last phrase)"]
        var rows = order.compactMap { k in m[k].map { (k, $0) } }
        rows.insert(("t_translate warm (every phrase)", allTr), at: rows.count - 3)
        report(summaryTable("Them → You [\(variant)] ADPCM=\(adpcm ? 1 : 0) stream=\(continuous ? "continuous" : "vad") finalize=\(finalize ? 1 : 0)\(finalizeAtLast ? "@last" : "") pad=\(pad) hang=\(BoardVAD().hangoverFrames * 20) gap=\(pauseGap) rec=\(exp ? "exp fast=\(fast ? 1 : 0)" : "app") tts=\(tts.mode.rawValue) translator=\(Translator.strategy)", rows))
        let missed = tl.utterances.filter { u in !finals.contains { $0.utt == u.index } }.map(\.index)
        if !missed.isEmpty { report("  no final attributed to utterance(s) \(missed)") }
        for f in finals { report(String(format: "  %6.2fs u%-2@ %@  →  %@", f.t, f.utt.map(String.init) ?? "?", f.text, f.translated)) }
    }
}
