package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Port of ios/Tests/TranslatorCoreTests/VoiceGateTests.swift. The Swift suite has no WAV fixtures: it
 * synthesizes its mic signals (voiced talker, noise, babble) at 16 kHz, so [Signal] below is a 1:1 port of
 * the Swift generator (same PRNG, same formulas) and every expectation is the Swift one.
 */
private class Signal {
    private var seed: Long = -0x61c8864680b583ebL // 0x9E3779B97F4A7C15

    fun uniform(): Float {
        seed = seed * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
        return (seed ushr 40).toFloat() / (1 shl 24).toFloat() * 2 - 1
    }

    fun noise(seconds: Double, db: Float): FloatArray {
        val a = amplitude(db) * 1.73f // uniform noise RMS = 1/sqrt(3)
        return FloatArray((seconds * RATE).toInt()) { uniform() * a }
    }

    companion object {
        const val RATE = 16_000.0

        fun amplitude(db: Float): Float = 10f.pow(db / 20)

        /** A talker: pitch [f0] with slow vibrato, 10 harmonics, syllables whose troughs are [gapDB] below the peaks */
        fun voice(
            seconds: Double, db: Float, f0: Double = 140.0, syllableRate: Double = 4.0,
            gapDB: Float = -12f, phase: Double = 0.0,
        ): FloatArray {
            val n = (seconds * RATE).toInt()
            val out = FloatArray(n)
            var theta = 0.0
            val floorGain = amplitude(gapDB).toDouble()
            for (i in 0 until n) {
                val t = i / RATE
                theta += 2 * PI * f0 * (1 + 0.03 * sin(2 * PI * 5 * t + phase)) / RATE
                var s = 0.0
                for (k in 1..10) s += sin(k * theta) / k
                val env = floorGain + (1 - floorGain) * sin(PI * syllableRate * t + phase).pow(2)
                out[i] = (s * env).toFloat()
            }
            return scaled(out, db)
        }

        /** Several talkers at different pitches and rhythms */
        fun babble(seconds: Double, db: Float): FloatArray {
            val talkers = listOf(118.0 to 3.1, 167.0 to 3.7, 203.0 to 4.3, 131.0 to 4.9, 241.0 to 3.4, 149.0 to 5.2)
            val mix = FloatArray((seconds * RATE).toInt())
            talkers.forEachIndexed { i, (f0, syl) ->
                val v = voice(seconds, -20f, f0, syl, -25f, i * 1.3)
                for (j in mix.indices) mix[j] += v[j]
            }
            return scaled(mix, db)
        }

        fun scaled(x: FloatArray, db: Float): FloatArray {
            var sum = 0f
            for (v in x) sum += v * v
            val rms = sqrt(sum / max(1, x.size).toFloat())
            val g = if (rms > 0) amplitude(db) / rms else 0f
            return FloatArray(x.size) { x[it] * g }
        }

        fun mix(a: FloatArray, b: FloatArray): FloatArray =
            FloatArray(max(a.size, b.size)) { (if (it < a.size) a[it] else 0f) + (if (it < b.size) b[it] else 0f) }

        fun zeros(seconds: Int) = FloatArray(seconds * 16_000)
    }
}

/** Runs a whole signal through a gate in 341-sample (21 ms) buffers; passed seconds, end and open times */
private class GateRun(samples: FloatArray, gate: VoiceGate = VoiceGate(), int16: Boolean = true) {
    var passed = 0.0
    val ends = mutableListOf<Double>()
    /** Input time of the first audio passed after each opening */
    val opens = mutableListOf<Double>()

    init {
        var t = 0
        var open = false
        val rate = Signal.RATE.toInt()
        while (t < samples.size) {
            val n = min(341, samples.size - t)
            val chunk = samples.copyOfRange(t, t + n)
            t += n
            val events = if (int16) gate.process(VoiceGate.toPcm16(chunk), rate) else gate.process(chunk, rate)
            for (event in events) {
                when (event) {
                    is VoiceGate.Event.Audio -> {
                        val s = event.samples.size / Signal.RATE
                        if (!open) { opens.add(t / Signal.RATE - s); open = true }
                        passed += s
                    }
                    VoiceGate.Event.Ended -> {
                        ends.add(t / Signal.RATE)
                        open = false
                    }
                }
            }
        }
    }

    override fun toString() = "opens $opens ends $ends passed $passed"
}

private operator fun FloatArray.plus(other: FloatArray): FloatArray {
    val out = copyOf(size + other.size)
    other.copyInto(out, size)
    return out
}

class VoiceGateTest {
    @Test fun passesSpeechWithPrerollAndEndsAfterHangover() {
        val s = Signal()
        val x = s.noise(2.0, -62f) + Signal.mix(Signal.voice(2.0, -20f), s.noise(2.0, -62f)) + s.noise(2.0, -62f)
        val run = GateRun(x)
        assertEquals(run.toString(), 1, run.ends.size)
        // Opens at most 0.3 s before the speech (pre-roll) and not after it started
        assertEquals(run.toString(), 1, run.opens.size)
        assertTrue(run.toString(), run.opens[0] in 1.65..2.0)
        // Ends 0.8 s after the voice stops (plus a frame or two)
        assertTrue(run.toString(), run.ends[0] in 4.75..4.95)
        // Everything spoken was passed: pre-roll + 2 s + hangover
        assertTrue(run.toString(), run.passed in (2.0 + 0.8)..3.3)
    }

    @Test fun floatBuffersBehaveLikeInt16() {
        val s = Signal()
        val x = s.noise(1.0, -62f) + Signal.voice(1.5, -24f) + s.noise(1.5, -62f)
        val a = GateRun(x, int16 = true)
        val b = GateRun(x, int16 = false)
        assertTrue("$a / $b", a.ends.size == 1 && b.ends.size == 1)
        assertTrue("$a / $b", abs(a.passed - b.passed) < 0.05)
    }

    /** The old energy gate's floor rose 0.5 dB/s, so in sustained babble it never closed */
    @Test fun staysClosedInSustainedBabble() {
        // Before the wearer has spoken it may open briefly on a babble peak; it must not stay open
        val cold = GateRun(Signal.babble(20.0, -30f))
        assertTrue(cold.toString(), cold.passed < 2.5)
        // Once the wearer (-18 dB at the mic) has been heard, 20 s of babble at -30 dB pass nothing
        val wearer = Signal.voice(3.0, -18f) + Signal.zeros(20)
        val warm = GateRun(Signal.mix(wearer, Signal.zeros(3) + Signal.babble(20.0, -30f)))
        assertTrue(warm.toString(), warm.passed < 3 + 0.3 + 0.9 + 0.5)
    }

    @Test fun opensForTheWearerOverBabble() {
        val babble = Signal.babble(12.0, -30f)
        val voice = Signal.zeros(6) + Signal.voice(3.0, -20f)
        val run = GateRun(Signal.mix(babble, voice))
        assertTrue(run.toString(), run.opens.any { it in 5.6..6.1 })
        // The wearer's 3 s with pre-roll and hangover, plus at most a brief cold-start opening on babble
        assertTrue(run.toString(), run.passed >= 3.0 && run.passed < 4.1 + 2.5)
    }

    @Test fun ignoresAQuieterBystanderOnceTheWearerIsKnown() {
        val s = Signal()
        val wearer = Signal.voice(3.0, -18f)
        val bystander = Signal.voice(3.0, -34f, f0 = 210.0, syllableRate = 3.3)
        val x = Signal.mix(
            s.noise(1.0, -62f) + wearer + s.noise(2.0, -62f) + bystander + s.noise(1.0, -62f),
            s.noise(10.0, -62f),
        )
        val run = GateRun(x)
        assertEquals("only the wearer opens the gate, $run", 1, run.opens.size)
        assertTrue(run.toString(), run.passed < 3 + 0.3 + 0.9)
    }

    /** A 30 s sentence without real pauses in loud babble (3 dB below the voice) must never be cut */
    @Test fun neverCutsALongSentenceInLoudBabble() {
        val babble = Signal.babble(36.0, -23f)
        val voice = Signal.zeros(3) + Signal.voice(30.0, -20f, gapDB = -20f)
        val run = GateRun(Signal.mix(babble, voice))
        val during = run.ends.filter { it > 3.5 && it < 33 }
        assertTrue("gate closed mid-sentence at $during", during.isEmpty())
        assertTrue(run.toString(), run.passed >= 30)
    }

    /** Review C1: one loud call-out must not lock out the wearer's normal speech */
    @Test fun aShoutDoesNotLockOutNormalSpeech() {
        val s = Signal()
        val normal = Signal.voice(3.0, -20f)
        var x = s.noise(0.5, -62f) + normal + s.noise(1.5, -62f) + Signal.voice(1.0, -6f) + s.noise(1.5, -62f)
        repeat(3) { x = x + normal + s.noise(1.5, -62f) }
        val run = GateRun(x)
        assertEquals(run.toString(), 5, run.opens.size)
        assertTrue(run.toString(), run.passed >= 3 + 1 + 3 * 3)
    }

    /** Review I1: a sentence whose last second is 14 dB softer must not lose its ending */
    @Test fun keepsASoftEnding() {
        val s = Signal()
        val x = s.noise(0.5, -62f) + Signal.voice(3.0, -20f) + s.noise(1.5, -62f) +
            Signal.voice(2.0, -20f) + Signal.voice(1.2, -34f) + s.noise(2.0, -62f)
        val run = GateRun(x)
        assertEquals(run.toString(), 2, run.ends.size)
        // second utterance ends at 0.5 + 3 + 1.5 + 3.2 = 8.2 s; the gate must close only after it
        assertTrue(run.toString(), run.ends.last() >= 8.2 + 0.7)
    }

    /** Review I2: after the mic gain drops 14 dB the wearer gets through again within a few seconds */
    @Test fun relearnsAfterAGainDrop() {
        val s = Signal()
        var x = s.noise(0.5, -62f) + Signal.voice(3.0, -18f) + s.noise(1.5, -62f)
        val start = x.size / Signal.RATE
        repeat(4) { x = x + Signal.voice(2.0, -32f) + s.noise(1.0, -76f) }
        val run = GateRun(x)
        val later = run.opens.filter { it > start }
        assertTrue(run.toString(), later.size >= 2)
        // the first lowered utterance may be lost while the gate relearns, the rest must pass
        assertTrue(run.toString(), run.passed >= 3 + 3 * 2)
    }

    @Test fun routeChangeForgetsTheWearer() {
        val s = Signal()
        val gate = VoiceGate()
        GateRun(s.noise(0.5, -62f) + Signal.voice(3.0, -14f) + s.noise(1.5, -62f), gate)
        gate.resetWearerLevel()
        val run = GateRun(Signal.voice(2.0, -34f) + s.noise(1.5, -62f), gate)
        assertEquals(run.toString(), 1, run.opens.size)
    }

    /** Review I3: while you only listen for minutes, the person you talk to must not open the gate */
    private fun partnerStaysOutDuringLongListening(quieterBy: Float) {
        val s = Signal()
        var x = s.noise(0.5, -62f) + Signal.voice(3.0, -18f) + s.noise(1.5, -62f)
        val start = x.size / Signal.RATE
        val partner = Signal.mix(Signal.voice(4.0, -18 - quieterBy, f0 = 210.0, syllableRate = 3.3), s.noise(4.0, -62f))
        val parts = ArrayList<FloatArray>()
        parts.add(x)
        repeat(60) { parts.add(partner); parts.add(s.noise(1.0, -62f)) } // 5 minutes
        x = FloatArray(parts.sumOf { it.size }).also { out ->
            var at = 0
            for (p in parts) { p.copyInto(out, at); at += p.size }
        }
        val run = GateRun(x)
        val later = run.opens.filter { it > start }
        assertTrue("partner opened the gate at ${later.take(5)}", later.isEmpty())
    }

    @Test fun partnerStaysOutDuringLongListening15() = partnerStaysOutDuringLongListening(15f)
    @Test fun partnerStaysOutDuringLongListening20() = partnerStaysOutDuringLongListening(20f)

    /** The speech-presence check that keeps non-speech away from Whisper */
    @Test fun voicedSecondsFindsSpeechNotNoise() {
        val s = Signal()
        val speech = VoiceGate.voicedSeconds(s.noise(1.0, -62f) + Signal.voice(2.0, -30f) + s.noise(1.0, -62f), 16_000)
        assertTrue("speech: $speech", speech >= 1.5)
        assertEquals(0.0, VoiceGate.voicedSeconds(s.noise(3.0, -45f), 16_000), 0.05)
        assertEquals(0.0, VoiceGate.voicedSeconds(FloatArray(3 * 16_000), 16_000), 0.0)
        // Too quiet to count, even if voiced
        assertEquals(0.0, VoiceGate.voicedSeconds(Signal.voice(2.0, -70f), 16_000), 0.0)
    }

    @Test fun pcm16RoundTripMatchesSwiftScaling() {
        val pcm = VoiceGate.toPcm16(floatArrayOf(0f, 0.5f, -1f, 1.5f, -0.00002f))
        assertEquals(listOf<Short>(0, 16384, -32768, 32767, -1), pcm.toList())
        val back = VoiceGate.toFloats(pcm)
        assertEquals(0.5f, back[1], 0f)
        assertEquals((-1f), back[2], 0f)
    }
}
