import AVFAudio
import Testing
@testable import TranslatorCore

/// Synthetic mic signals at 16 kHz: a voiced talker (harmonics with syllable-rate level changes), noise and
/// multi-talker babble, fed to VoiceGate in 21 ms Int16 buffers like the converted AirPods mic.
struct Signal {
    static let rate = 16_000.0
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func uniform() -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(seed >> 40) / Float(1 << 24) * 2 - 1
    }

    static func amplitude(_ db: Float) -> Float { pow(10, db / 20) }

    mutating func noise(_ seconds: Double, db: Float) -> [Float] {
        let a = Self.amplitude(db) * 1.73  // uniform noise RMS = 1/sqrt(3)
        return (0..<Int(seconds * Self.rate)).map { _ in uniform() * a }
    }

    /// A talker: pitch `f0` with slow vibrato, 10 harmonics, syllables at `syllableRate` Hz whose troughs
    /// are `gapDB` below the peaks (short gaps between syllables, never true silence)
    static func voice(_ seconds: Double, db: Float, f0: Double = 140, syllableRate: Double = 4,
                      gapDB: Float = -12, phase: Double = 0) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var theta = 0.0
        let floorGain = Double(amplitude(gapDB))
        for i in 0..<n {
            let t = Double(i) / rate
            theta += 2 * .pi * f0 * (1 + 0.03 * sin(2 * .pi * 5 * t + phase)) / rate
            var s = 0.0
            for k in 1...10 { s += sin(Double(k) * theta) / Double(k) }
            let env = floorGain + (1 - floorGain) * pow(sin(.pi * syllableRate * t + phase), 2)
            out[i] = Float(s * env)
        }
        return scaled(out, to: db)
    }

    /// Several talkers at different pitches and rhythms
    static func babble(_ seconds: Double, db: Float) -> [Float] {
        let talkers = [(118.0, 3.1), (167.0, 3.7), (203.0, 4.3), (131.0, 4.9), (241.0, 3.4), (149.0, 5.2)]
        var mix = [Float](repeating: 0, count: Int(seconds * rate))
        for (i, (f0, syl)) in talkers.enumerated() {
            let v = voice(seconds, db: -20, f0: f0, syllableRate: syl, gapDB: -25, phase: Double(i) * 1.3)
            for j in 0..<mix.count { mix[j] += v[j] }
        }
        return scaled(mix, to: db)
    }

    static func scaled(_ x: [Float], to db: Float) -> [Float] {
        let rms = (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
        let g = rms > 0 ? amplitude(db) / rms : 0
        return x.map { $0 * g }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { ($0 < a.count ? a[$0] : 0) + ($0 < b.count ? b[$0] : 0) }
    }
}

/// Runs a whole signal through a gate; returns the passed seconds and the times of each `.ended`
struct GateRun {
    var passed = 0.0
    var ends: [Double] = []
    /// Input time of the first audio passed after each opening
    var opens: [Double] = []

    init(_ samples: [Float], gate: VoiceGate = VoiceGate(), int16: Bool = true) {
        let format = int16
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Signal.rate, channels: 1, interleaved: true)!
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Signal.rate, channels: 1, interleaved: false)!
        var t = 0
        var open = false
        while t < samples.count {
            let n = min(341, samples.count - t)
            let b = VoiceGate.buffer(Array(samples[t..<t + n]), format: format)!
            t += n
            for event in gate.process(b) {
                switch event {
                case .audio(let a):
                    let s = Double(a.frameLength) / Signal.rate
                    if !open { opens.append(Double(t) / Signal.rate - s); open = true }
                    passed += s
                case .ended:
                    ends.append(Double(t) / Signal.rate)
                    open = false
                }
            }
        }
    }
}

@Suite struct VoiceGateTests {
    @Test func passesSpeechWithPrerollAndEndsAfterHangover() {
        var s = Signal()
        let x = s.noise(2, db: -62) + Signal.mix(Signal.voice(2, db: -20), s.noise(2, db: -62)) + s.noise(2, db: -62)
        let run = GateRun(x)
        #expect(run.ends.count == 1)
        // Opens at most 0.3 s before the speech (pre-roll) and not after it started
        #expect(run.opens.count == 1)
        #expect(run.opens[0] >= 1.65 && run.opens[0] <= 2.0)
        // Ends 0.8 s after the voice stops (plus a frame or two)
        #expect(run.ends[0] >= 4.75 && run.ends[0] <= 4.95)
        // Everything spoken was passed: pre-roll + 2 s + hangover
        #expect(run.passed >= 2.0 + 0.8 && run.passed <= 3.3)
    }

    @Test func floatBuffersBehaveLikeInt16() {
        var s = Signal()
        let x = s.noise(1, db: -62) + Signal.voice(1.5, db: -24) + s.noise(1.5, db: -62)
        let a = GateRun(x, int16: true), b = GateRun(x, int16: false)
        #expect(a.ends.count == 1 && b.ends.count == 1)
        #expect(abs(a.passed - b.passed) < 0.05)
    }

    /// The old energy gate's floor rose 0.5 dB/s, so in sustained babble it never closed and the
    /// recognizer transcribed bystanders (46 % of Vietnamese errors in the spike)
    @Test func staysClosedInSustainedBabble() {
        // Before the wearer has spoken it may open briefly on a babble peak; it must not stay open
        let cold = GateRun(Signal.babble(20, db: -30))
        #expect(cold.passed < 2.5, "opens \(cold.opens) ends \(cold.ends)")
        // Once the wearer (-18 dB at the mic) has been heard, 20 s of babble at -30 dB pass nothing
        let wearer = Signal.voice(3, db: -18) + [Float](repeating: 0, count: 20 * 16_000)
        let warm = GateRun(Signal.mix(wearer, [Float](repeating: 0, count: 3 * 16_000) + Signal.babble(20, db: -30)))
        #expect(warm.passed < 3 + 0.3 + 0.9 + 0.5, "opens \(warm.opens) ends \(warm.ends)")
    }

    @Test func opensForTheWearerOverBabble() {
        let babble = Signal.babble(12, db: -30)
        let voice = [Float](repeating: 0, count: 6 * 16_000) + Signal.voice(3, db: -20)
        let run = GateRun(Signal.mix(babble, voice))
        #expect(run.opens.contains { $0 >= 5.6 && $0 <= 6.1 })
        // The wearer's 3 s with pre-roll and hangover, plus at most a brief cold-start opening on babble
        #expect(run.passed >= 3.0 && run.passed < 4.1 + 2.5, "opens \(run.opens) ends \(run.ends)")
    }

    @Test func ignoresAQuieterBystanderOnceTheWearerIsKnown() {
        var s = Signal()
        let wearer = Signal.voice(3, db: -18)
        let bystander = Signal.voice(3, db: -34, f0: 210, syllableRate: 3.3)
        let x = Signal.mix(s.noise(1, db: -62) + wearer + s.noise(2, db: -62) + bystander + s.noise(1, db: -62),
                           s.noise(10, db: -62))
        let run = GateRun(x)
        #expect(run.opens.count == 1, "only the wearer opens the gate, opens at \(run.opens)")
        #expect(run.passed < 3 + 0.3 + 0.9)
    }

    /// A 30 s sentence without real pauses in loud babble (3 dB below the voice) must never be cut
    @Test func neverCutsALongSentenceInLoudBabble() {
        let babble = Signal.babble(36, db: -23)
        let voice = [Float](repeating: 0, count: 3 * 16_000) + Signal.voice(30, db: -20, gapDB: -20)
        let run = GateRun(Signal.mix(babble, voice))
        let during = run.ends.filter { $0 > 3.5 && $0 < 33 }
        #expect(during.isEmpty, "gate closed mid-sentence at \(during)")
        #expect(run.passed >= 30)
    }

    @Test func aSofterVoiceIsNotLockedOutForLong() {
        var s = Signal()
        // Learned loud; the wearer then speaks 12 dB softer: shut out at first, through after a minute
        let soft = Signal.voice(2, db: -26)
        let x = s.noise(0.5, db: -62) + Signal.voice(3, db: -14) + s.noise(3, db: -62) + soft
            + s.noise(60, db: -62) + soft + s.noise(1, db: -62)
        let run = GateRun(x)
        #expect(run.opens.count == 2, "opens \(run.opens)")
        #expect(run.opens.last! > 60)
    }
}
