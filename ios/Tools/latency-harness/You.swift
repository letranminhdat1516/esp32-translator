// You → Them, wired like AppleVoiceEngine.takeMic + ConversationController.handleMine/makeSubtitles:
//   mic-tap-sized float buffers (341 frames, real time) → MicSource.handle (BufferConverter → VoiceGate) →
//   LiveTranscriber(DictationTranscriber vi-VN), finalizeNow() when the gate closes →
//   TurnAssembler → SubtitleTranslator(TextPipeline(.mine) over Translator vi→en) → "board text" (onResult).
// Experiments (harness only): GATE_HANG sets VoiceGate.Config.hangover (0.8 s); EARLY_FINALIZE=<s> runs a
// shadow VoiceGate with that hangover on the same audio and calls finalizeNow when it closes, while the real gate
// (GATE_HANG) still decides what is fed.
// Env: GATE=1 (0: no gate, continuous audio, no finalizeNow), FINALIZE=1 (0: gate on, no finalizeNow).
import AVFAudio
import Foundation

private struct Request {
    let text: String
    let final: Bool
    let requested: Double
    var start = Double.nan, end = Double.nan
    var dropped = false
}

@MainActor
final class YouRun {
    let tl: Timeline
    let variant: String
    let gateOn = envFlag("GATE", true)
    let finalize = envFlag("FINALIZE", true)
    private var t0 = 0.0
    private func rel() -> Double { now() - t0 }

    private let events = Log<TranscriptEvent>()
    private var finals: [(t: Double, text: String, utt: Int?)] = []
    private var turns = TurnAssembler()
    private var subtitles: SubtitleTranslator!
    private var requests: [Request] = []
    private var latestPartial: [Int: String] = [:]
    private var partialCalls = 0
    private var results: [(t: Double, english: String)] = []
    private var gateOpens: [Double] = []
    private var gateCloses: [Double] = []
    private var earlyFinalizes: [Double] = []
    private var translator: Translator?
    private var translations = 0
    private var coldMs = Double.nan
    private let pipeline: TextPipeline

    init(tl: Timeline, variant: String) throws {
        self.tl = tl
        self.variant = variant
        pipeline = try TextPipeline(home: SharedResources.languagePack("vi"), other: SharedResources.languagePack("en"))
    }

    func run(tsvPath: String) async throws {
        let home = LiveTranscriber(locale: Locale(identifier: "vi-VN"), engine: .dictation)
        let log = events
        let startLocal = now()
        try await home.start { [weak self] e in
            guard let self else { return }
            let t = now()
            log.add(t, e)
            Task { @MainActor in self.onEvent(e, at: t) }
        }
        report(String(format: "you: DictationTranscriber vi-VN started in %.0f ms", (now() - startLocal) * 1000))
        guard let format = home.audioFormat else { fatalError("no audio format") }
        subtitles = SubtitleTranslator(
            translate: { [weak self] text in await self?.translateMine(text) ?? text },
            onResult: { [weak self] _, english in
                guard let self else { return }
                self.results.append((self.rel(), english))
            })
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Same gate and hand-off as the app: MicSource with the app's default VoiceGate
        var config = VoiceGate.Config()
        if let h = env["GATE_HANG"].flatMap(Double.init) { config.hangover = h }
        let mic = MicSource(target: format, gate: VoiceGate(config: config), sink: { home.feed($0) },
                            onSpeechStart: { [weak self] in MainActor.assumeIsolated { self?.gateOpens.append(self!.rel()) } },
                            onSpeechEnd: { [weak self] in
                                if self?.finalize == true { home.finalizeNow() }
                                MainActor.assumeIsolated { self?.gateCloses.append(self!.rel()) }
                            })
        let converter = BufferConverter(target: format)
        var shadow: MicSource?
        if let early = env["EARLY_FINALIZE"].flatMap(Double.init) {
            var c = config
            c.hangover = early
            shadow = MicSource(target: format, gate: VoiceGate(config: c), sink: { _ in },
                               onSpeechEnd: { [weak self] in
                                   home.finalizeNow()
                                   MainActor.assumeIsolated { self?.earlyFinalizes.append(self!.rel()) }
                               })
        }
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let tap = 341
        t0 = now()
        var p = 0
        while p < tl.samples.count {
            let n = min(tap, tl.samples.count - p)
            let b = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            tl.samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + p, count: n) }
            p += n
            await sleepUntil(t0 + Double(p) / sampleRate)
            if gateOn {
                shadow?.handle(b)
                mic.handle(b)
            } else if let c = converter.convert(b) {
                home.feed(c)
            }
        }
        let deadline = now() + 10
        while now() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            if requests.allSatisfy({ $0.end.isFinite }) && now() - t0 > tl.duration + 2 { break }
        }
        await subtitles.idle()
        await home.stop()
        write(tsvPath)
    }

    private func onEvent(_ e: TranscriptEvent, at tAbs: Double) {
        let t = tAbs - t0
        if case .final(let text, _, _) = e, !text.isEmpty {
            finals.append((t, text, attribute(text, at: t, tl.utterances)))
        }
        // ConversationController.handleMine
        guard let change = turns.handle(e, at: Date()), let turn = turns.turn else { return }
        if let final = change.final {
            requests.append(Request(text: final, final: true, requested: rel()))
            subtitles.addFinal(final, turn: turn.id)
        }
        if latestPartial[turn.id] != turn.partial {
            latestPartial[turn.id] = turn.partial
            if !turn.partial.isEmpty {
                partialCalls += 1
                requests.append(Request(text: turn.partial, final: false, requested: rel()))
            }
        }
        subtitles.setPartial(turn.partial, turn: turn.id)
    }

    /// ConversationController.translateMine: TextPipeline(vi→X) through the engine's lazily made translator
    private func translateMine(_ text: String) async -> String {
        if translator == nil {
            translator = Translator(from: Locale.Language(identifier: "vi"), to: Locale.Language(identifier: "en"))
        }
        let tr = translator!
        // The newest request with this text not yet started
        let i = requests.lastIndex { $0.text == text && !$0.start.isFinite }
        if let i { requests[i].start = rel() }
        let cold = translations == 0
        translations += 1
        let a = now()
        let out = (try? await pipeline.translate(text, .mine) { @Sendable in try await tr.translate($0) }) ?? text
        if cold { coldMs = now() - a }
        if let i {
            requests[i].end = rel()
            // SubtitleTranslator drops a volatile translation whose phrase changed or was finalized meanwhile
            if !requests[i].final { requests[i].dropped = !latestPartial.values.contains(text) }
        }
        return out
    }

    private func write(_ path: String) {
        let partials = events.all.compactMap { (t, e) -> Double? in
            if case .partial(let s, _) = e, !s.isEmpty { return t - t0 }
            return nil
        }
        let tsv = try! TSV(path, header: ["dir", "variant", "utt", "text", "speech_start", "speech_end",
                                          "first_volatile_from_start", "gate_open_after_start", "gate_close_after_end",
                                          "final_first_after_end", "final_last_after_end", "gate_close_to_final",
                                          "n_finals", "recognized", "translate_ms_last_final", "first_subtitle_from_start",
                                          "e2e_final_subtitle_ms", "subtitle", "wer", "exact"])
        var exact = 0, splits = 0, werSum = 0.0
        var m: [String: [Double]] = [:]
        func add(_ k: String, _ v: Double) { m[k, default: []].append(v) }
        for (n, u) in tl.utterances.enumerated() {
            let nextStart = n + 1 < tl.utterances.count ? tl.utterances[n + 1].start : .infinity
            let fv = partials.first { $0 >= u.start && $0 < nextStart }.map { $0 - u.start } ?? .nan
            let go = gateOpens.first { $0 >= u.start - 0.3 && $0 < nextStart }.map { $0 - u.start } ?? .nan
            let gc = gateCloses.first { $0 >= u.end && $0 < nextStart }
            let mine = finals.filter { $0.utt == u.index }
            let ff = mine.first.map { $0.t - u.end } ?? .nan
            let fl = mine.last.map { $0.t - u.end } ?? .nan
            let g2f = (mine.last != nil && gc != nil) ? mine.last!.t - gc! : .nan
            // The last final of this utterance: its translation, then the first subtitle update after it
            var trMs = Double.nan, e2e = Double.nan, subtitle = ""
            // (the request addFinal made when this final was handled; its text is the fixed-up final)
            if let lf = mine.last, let r = requests.first(where: { $0.final && $0.requested >= lf.t - 0.001 }), r.end.isFinite {
                trMs = r.end - r.start
                if let res = results.first(where: { $0.t >= r.end - 0.001 }) { e2e = res.t - u.end; subtitle = res.english }
            }
            let fs = results.first { $0.t >= u.start && $0.t < nextStart && !$0.english.isEmpty }.map { $0.t - u.start } ?? .nan
            add("t_first_volatile (from speech start)", fv)
            if gateOn { add("gate open (from speech start)", go); add("gate close (after speech end)", gc.map { $0 - u.end } ?? .nan) }
            add("t_final first phrase (after speech end)", ff)
            add("t_final last phrase (after speech end)", fl)
            if gateOn { add("gate close → final", g2f) }
            add("first subtitle shown (from speech start)", fs)
            add("t_translate final phrase", trMs)
            add("E2E speech end → final subtitle ready", e2e)
            let recognized = mine.map(\.text).joined(separator: " ")
            let w = wer(recognized, u.text, vietnamese: true)
            werSum += w
            if w == 0 { exact += 1 }
            if mine.count > 1 { splits += mine.count - 1 }
            if let ef = earlyFinalizes.first(where: { $0 >= u.end && $0 < nextStart }) { add("early finalizeNow (after speech end)", ef - u.end) }
            tsv.write(["you", variant, String(u.index), u.text, String(format: "%.3f", u.start), String(format: "%.3f", u.end),
                       ms(fv), ms(go), ms(gc.map { $0 - u.end } ?? .nan), ms(ff), ms(fl), ms(g2f), String(mine.count),
                       mine.map(\.text).joined(separator: " | "), ms(trMs), ms(fs), ms(e2e), subtitle,
                       String(format: "%.2f", w), w == 0 ? "1" : "0"])
        }
        tsv.close()
        // Merged: a final that carries words of more than one utterance (the others then have no final)
        let missing = tl.utterances.filter { u in !finals.contains { $0.utt == u.index } }.count
        let fl = m["t_final last phrase (after speech end)"] ?? [], e2eAll = m["E2E speech end → final subtitle ready"] ?? []
        report("RESULT\tyou\t\(variant)\texact=\(exact)/\(tl.utterances.count)\twer=\(String(format: "%.3f", werSum / Double(tl.utterances.count)))\tsplits=\(splits)\tmerged_away=\(missing)\tfinal_last_p50=\(ms(percentile(fl, 0.5)))\tp90=\(ms(percentile(fl, 0.9)))\tn=\(fl.filter(\.isFinite).count)\te2e_p50=\(ms(percentile(e2eAll, 0.5)))\tp90=\(ms(percentile(e2eAll, 0.9)))")
        let partialDone = requests.filter { !$0.final && $0.end.isFinite && !$0.dropped }
        let volatileLatency = partialDone.map { $0.end - $0.requested }
        let volatileTranslate = partialDone.map { $0.end - $0.start }
        let skipped = requests.filter { !$0.final && !$0.start.isFinite }.count
        let dropped = requests.filter { $0.dropped }.count
        let order = ["t_first_volatile (from speech start)", "gate open (from speech start)", "early finalizeNow (after speech end)", "gate close (after speech end)",
                     "t_final first phrase (after speech end)", "t_final last phrase (after speech end)", "gate close → final",
                     "first subtitle shown (from speech start)", "t_translate final phrase"]
        var rows = order.compactMap { k in m[k].map { (k, $0) } }
        rows.append(("volatile update → its subtitle", volatileLatency))
        rows.append(("  of which translate call", volatileTranslate))
        rows.append(("t_translate COLD (first call of the run)", [coldMs]))
        rows.append(("E2E speech end → final subtitle ready", m["E2E speech end → final subtitle ready"] ?? []))
        report(summaryTable("You → Them [\(variant)] gate=\(gateOn ? 1 : 0) finalizeNow=\(finalize && gateOn ? 1 : 0) translator=\(Translator.strategy)", rows))
        report("  volatile updates: \(partialCalls), translated and shown \(partialDone.count), superseded before start \(skipped), dropped after translating \(dropped)")
        let missed = tl.utterances.filter { u in !finals.contains { $0.utt == u.index } }.map(\.index)
        if !missed.isEmpty { report("  no final attributed to utterance(s) \(missed)") }
        for f in finals { report(String(format: "  %6.2fs u%-2@ %@", f.t, f.utt.map(String.init) ?? "?", f.text)) }
    }
}
