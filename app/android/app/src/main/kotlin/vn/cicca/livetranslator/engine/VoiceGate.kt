package vn.cicca.livetranslator.engine

import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Own-voice gate for the headset mic: passes audio to the Vietnamese recognizer only while the wearer speaks.
 *
 * A faithful port of `ios/Sources/Audio/VoiceGate.swift` (same configuration, same per-frame decisions,
 * same tests in `VoiceGateTest`). See the Swift file for the measurements behind each constant.
 *
 * A 20 ms frame opens the gate only if it is well above the background level, voiced (periodic at a speech
 * pitch) and near the wearer's own learned level. The gate keeps 300 ms of pre-roll so the first syllable is
 * not cut, and closes 0.8 s after the voice stops. The background level is a low percentile of the frame
 * levels over the last 3 s. The wearer's level is learned per utterance (90th percentile of its voiced
 * frames), smoothed as the median of the last five utterances weighted by their length, and allowed to rise
 * at most 6 dB per utterance. It is forgotten on an audio route change, and relearned when the gate keeps
 * rejecting voice that stands out from the background as much as the wearer's does (a mic gain drop).
 *
 * Not thread-safe except [resetWearerLevel]: call [process] from one thread.
 */
class VoiceGate(
    val config: Config = Config(),
    private val log: (String) -> Unit = {},
) {
    data class Config(
        /** Audio kept from before the gate opens, so the first syllable is not cut */
        val preroll: Double = 0.3,
        /** The gate closes after this much non-speech */
        val hangover: Double = 0.8,
        /** Analysis frame */
        val frame: Double = 0.02,
        /** Background level: this percentile of frame levels over the last [floorWindow] seconds */
        val floorWindow: Double = 3.0,
        val floorPercentile: Double = 0.05,
        /** A frame counts as the wearer's voice only this far above the background… */
        val openMarginDB: Float = 8f,
        /** …and keeps the gate open while this far above it and voiced */
        val holdMarginDB: Float = 6f,
        /** Never open below this absolute level (quiet room hiss) */
        val minDB: Float = -58f,
        /** Opening needs frames within this of the wearer's level */
        val nearMarginDB: Float = 8f,
        /** Holding needs [holdNearMarginDB]; while the voice continues without a gap longer than [softHoldGap]
         *  it only needs [softHoldNearMarginDB] */
        val holdNearMarginDB: Float = 8f,
        val softHoldNearMarginDB: Float = 20f,
        val softHoldGap: Double = 0.3,
        /** Each utterance votes with this percentile of its loud voiced frames */
        val userPercentile: Double = 0.9,
        /** An utterance needs this much loud voiced speech to teach the wearer's level */
        val learnMinSpeech: Double = 0.5,
        /** Median of the last [learnUtterances] utterances, rising at most [maxRisePerUtterance] dB each */
        val learnUtterances: Int = 5,
        val maxRisePerUtterance: Float = 6f,
        /** While closed the level sinks by this much per second, never more than [maxDecayDB] below the last learned */
        val decayPerSecond: Float = 0.05f,
        val maxDecayDB: Float = 5f,
        /** Relearn after a mic gain drop (see the Swift file) */
        val relearnMarginDB: Float = 15f,
        val relearnSlackDB: Float = 4f,
        val relearnFloorDropDB: Float = 6f,
        val relearnWindow: Double = 1.5,
        val relearnSpeech: Double = 0.5,
        /** Normalized autocorrelation peak at the pitch period (0…1) for a frame to count as voiced */
        val voicing: Float = 0.45f,
        /** Opening needs [onsetFrames] loud, voiced frames within [onsetWindow] */
        val onsetWindow: Double = 0.2,
        val onsetFrames: Int = 4,
        /** Pitch search range */
        val minPitchHz: Double = 80.0,
        val maxPitchHz: Double = 400.0,
    )

    sealed class Event {
        /** Audio to pass to the recognizer, as floats in −1…1 at the input sample rate */
        class Audio(val samples: FloatArray) : Event()
        /** The wearer stopped speaking: finalize */
        data object Ended : Event()
    }

    private var sampleRate = 0
    private var frameLength = 0
    private var minLag = 0
    private var maxLag = 0

    private var pending = FloatArray(0)
    private var pendingCount = 0
    private var frame = FloatArray(0)
    private var history = Ring(1)
    private var analysis = Ring(1)
    private var analysisScratch = FloatArray(0)

    private var levels = Ring(1)
    private var sortScratch = FloatArray(0)
    var floorDB = -100f
        private set
    private var quartileDB = -100f
    private var openFloorDB = -100f
    private var openQuartileDB = -100f

    var userLevelDB: Float? = null
        private set
    private var userFloorDB: Float? = null
    private var userQuartileDB: Float? = null
    private val recentFloors = ArrayList<Float>()
    private val recentWeights = ArrayList<Float>()
    private val recentQuartiles = ArrayList<Float>()
    private var lastLearnedDB = 0f
    private val recentLevels = ArrayList<Float>()
    private val utteranceLevels = ArrayList<Float>()
    private var utteranceCount = 0
    private var rejected = BooleanArray(0)
    private var rejectedIndex = 0
    private var rejectedCount = 0
    private val resetRequested = AtomicBoolean(false)

    private var onset = BooleanArray(0)
    private var onsetIndex = 0
    private var onsetFilled = 0
    private var speaking = false
    private var silentFor = 0.0
    private var sinceHeld = 0.0

    var framesAnalyzed = 0
        private set
    var pitchAnalyses = 0
        private set

    val isOpen: Boolean get() = speaking

    /** Forget the wearer's level (audio route changed). Safe from any thread; applied before the next buffer. */
    fun resetWearerLevel() {
        resetRequested.set(true)
    }

    /** 16-bit PCM input (the mic's native format), scaled by 1/32768 like vDSP_vflt16 + vDSP_vsmul */
    fun process(pcm: ShortArray, sampleRate: Int): List<Event> = process(toFloats(pcm), sampleRate)

    /** Splits the buffer into frames and returns what to send to the recognizer, in order */
    fun process(samples: FloatArray, sampleRate: Int): List<Event> {
        if (sampleRate != this.sampleRate) configure(sampleRate)
        if (resetRequested.getAndSet(false)) forgetWearer("route change")
        val events = ArrayList<Event>(2)
        val out = FloatList()
        val n = samples.size
        var i = 0
        while (i < n) {
            val take = min(frameLength - pendingCount, n - i)
            samples.copyInto(pending, pendingCount, i, i + take)
            pendingCount += take
            i += take
            if (pendingCount == frameLength) {
                val t = pending; pending = frame; frame = t
                pendingCount = 0
                step(out, events)
            }
        }
        if (out.size > 0) events.add(Event.Audio(out.toArray()))
        return events
    }

    // Per frame

    private fun step(out: FloatList, events: MutableList<Event>) {
        framesAnalyzed += 1
        analysis.append(frame)

        val db = levelDB(frame)
        levels.append(db)
        levels.percentiles(config.floorPercentile, 0.25, sortScratch).let { (f, q) -> floorDB = f; quartileDB = q }
        val floor = floorDB
        val level = userLevelDB
        val near = level?.let { db >= it - config.nearMarginDB } ?: true
        val continuing = sinceHeld <= config.softHoldGap
        val holdMargin = if (continuing) config.softHoldNearMarginDB else config.holdNearMarginDB
        val nearish = level?.let { db >= it - holdMargin } ?: true
        val loud = db > floor + config.openMarginDB && db > config.minDB && near
        val held = db > floor + config.holdMarginDB && db > config.minDB && nearish
        // Voice rejected only for being quieter than the wearer: a candidate for relearning
        var standsOut = false
        val learnedFloor = userFloorDB
        val learnedQuartile = userQuartileDB
        if (!speaking && !near && learnedFloor != null && learnedQuartile != null &&
            db > config.minDB && db > floor + config.relearnMarginDB &&
            learnedQuartile - quartileDB >= config.relearnFloorDropDB
        ) {
            val drop = learnedFloor - floor
            val expected = level - drop
            standsOut = drop >= config.relearnFloorDropDB && db >= expected - config.nearMarginDB &&
                db <= expected + config.relearnSlackDB
        }
        // The pitch analysis only runs when the level could open, hold or relearn
        val voiced = if (loud || (speaking && held) || standsOut) isVoiced() else false

        if (speaking) {
            if (voiced && db > floor + config.openMarginDB && db > config.minDB) {
                if (utteranceLevels.size < 1500) utteranceLevels.add(db)
                utteranceCount += 1
                // Not learned yet: estimate from this utterance after 1 s of speech, refine twice a second
                if (recentLevels.isEmpty() && utteranceCount >= 50 && utteranceCount % 25 == 0) {
                    val p = percentile(utteranceLevels, config.userPercentile)
                    userLevelDB = p
                    lastLearnedDB = p
                }
            }
            if (held && voiced) {
                silentFor = 0.0
                sinceHeld = 0.0
            } else {
                sinceHeld += config.frame
                silentFor += config.frame
                if (silentFor > config.hangover) {
                    speaking = false
                    learnFromUtterance()
                    log("gate: closed, background %.0f dB, voice %s".format(floorDB, describeLevel()))
                    clearOnset()
                    history.removeAll()
                    if (out.size > 0) events.add(Event.Audio(out.toArray()))
                    out.clear()
                    events.add(Event.Ended)
                    history.append(frame)
                    return
                }
            }
            out.addAll(frame)
            return
        }

        history.append(frame)
        userLevelDB?.let { l ->
            userLevelDB = max(lastLearnedDB - config.maxDecayDB, l - config.decayPerSecond * config.frame.toFloat())
        }
        if (trackRejected(standsOut && voiced)) {
            forgetWearer("voice standing out like yours was rejected (mic gain changed?)")
        }

        onset[onsetIndex] = loud && voiced
        onsetIndex = (onsetIndex + 1) % onset.size
        onsetFilled = min(onsetFilled + 1, onset.size)
        var count = 0
        var firstAge = 0
        for (age in 0 until onsetFilled) {
            if (onset[(onsetIndex - 1 - age + onset.size) % onset.size]) {
                count += 1
                firstAge = age
            }
        }
        if (count < config.onsetFrames) return

        // Open: send the pre-roll before the first voiced frame, then everything since
        val keep = (firstAge + 1) * frameLength + (config.preroll * sampleRate).toInt()
        history.appendSuffix(keep, out)
        log("gate: open at %.0f dB, background %.0f dB, voice %s".format(db, floor, describeLevel()))
        history.removeAll()
        clearOnset()
        speaking = true
        silentFor = 0.0
        sinceHeld = 0.0
        openFloorDB = floorDB
        openQuartileDB = quartileDB
        utteranceLevels.clear()
        utteranceCount = 0
    }

    private fun describeLevel() = userLevelDB?.let { "%.0f dB".format(it) } ?: "not learned"

    private fun clearOnset() {
        onset.fill(false)
        onsetIndex = 0
        onsetFilled = 0
    }

    private fun configure(sampleRate: Int) {
        this.sampleRate = sampleRate
        frameLength = max(1, (config.frame * sampleRate).toInt())
        minLag = (sampleRate / config.maxPitchHz).toInt()
        maxLag = (sampleRate / config.minPitchHz).toInt()
        pending = FloatArray(frameLength)
        frame = FloatArray(frameLength)
        pendingCount = 0
        val analysisLength = max(frameLength, 2 * maxLag + frameLength / 2)
        analysis = Ring(analysisLength)
        analysisScratch = FloatArray(analysisLength)
        history = Ring(((config.preroll + config.onsetWindow) * sampleRate).toInt() + frameLength)
        val n = max(1, Math.round(config.floorWindow / config.frame).toInt())
        levels = Ring(n)
        sortScratch = FloatArray(n)
        onset = BooleanArray(max(1, Math.round(config.onsetWindow / config.frame).toInt()))
        clearOnset()
        rejected = BooleanArray(max(1, Math.round(config.relearnWindow / config.frame).toInt()))
        speaking = false
        forgetWearer(null)
    }

    // Wearer level

    /** At the end of an utterance: its 90th-percentile level becomes one vote (weighted by its speech time) */
    private fun learnFromUtterance() {
        val speech = utteranceCount * config.frame
        if (speech < config.learnMinSpeech) return
        val firstVote = recentLevels.isEmpty()
        recentLevels.add(percentile(utteranceLevels, config.userPercentile))
        recentWeights.add(speech.toFloat())
        recentFloors.add(openFloorDB)
        recentQuartiles.add(openQuartileDB)
        if (recentLevels.size > config.learnUtterances) {
            recentLevels.removeAt(0)
            recentWeights.removeAt(0)
            recentFloors.removeAt(0)
            recentQuartiles.removeAt(0)
        }
        // Median weighted by speech time: a 1 s call-out cannot outvote sentences
        // (stable sort, like Swift's sorted(by:) on indices)
        val order = recentLevels.indices.sortedBy { recentLevels[it] }
        val half = recentWeights.sum() / 2
        var acc = 0f
        var target = recentLevels[order.last()]
        for (i in order) {
            acc += recentWeights[i]
            if (acc >= half) { target = recentLevels[i]; break }
        }
        val learned = if (firstVote || userLevelDB == null) target
        else min(target, lastLearnedDB + config.maxRisePerUtterance)
        userLevelDB = learned
        lastLearnedDB = learned
        userFloorDB = percentile(recentFloors, 0.5)
        userQuartileDB = percentile(recentQuartiles, 0.5)
    }

    private fun forgetWearer(reason: String?) {
        if (reason != null && userLevelDB != null) log("gate: forgetting your voice level ($reason)")
        userLevelDB = null
        userFloorDB = null
        userQuartileDB = null
        recentLevels.clear()
        recentFloors.clear()
        recentWeights.clear()
        recentQuartiles.clear()
        rejected.fill(false)
        rejectedCount = 0
    }

    /** Slides the relearn window; true when enough wearer-like voice was rejected in it */
    private fun trackRejected(isRejected: Boolean): Boolean {
        if (rejected.isEmpty()) return false
        if (rejected[rejectedIndex]) rejectedCount -= 1
        rejected[rejectedIndex] = isRejected
        if (isRejected) rejectedCount += 1
        rejectedIndex = (rejectedIndex + 1) % rejected.size
        return rejectedCount * config.frame >= config.relearnSpeech
    }

    // Voicing

    /** Peak of the normalized autocorrelation over the pitch range */
    private fun isVoiced(): Boolean {
        pitchAnalyses += 1
        val n = analysis.count
        if (n <= maxLag + 32) return false
        val x = analysisScratch
        analysis.copyInOrder(x)
        return peakAutocorrelation(x, n, minLag, maxLag) >= config.voicing
    }

    companion object {
        /**
         * Peak of the normalized autocorrelation of `x[0 until n]` over lags [minLag]…[maxLag] (0…1).
         * Removes the mean from [x] in place.
         */
        fun peakAutocorrelation(x: FloatArray, n: Int, minLag: Int, maxLag: Int): Float {
            var mean = 0f
            for (j in 0 until n) mean += x[j]
            mean /= n
            for (j in 0 until n) x[j] -= mean
            var best = 0f
            for (lag in minLag..min(maxLag, n - 32)) {
                val len = n - lag
                var r = 0f
                var e0 = 0f
                var e1 = 0f
                for (j in 0 until len) {
                    val a = x[j]
                    val b = x[j + lag]
                    r += a * b
                    e0 += a * a
                    e1 += b * b
                }
                val denom = sqrt(e0 * e1)
                if (denom > 0) best = max(best, r / denom)
            }
            return best
        }

        /**
         * Seconds of voiced speech in [samples]: 20 ms frames above [minDB] whose pitch analysis (the gate's,
         * same window and threshold) finds a speech pitch. Used to keep non-speech away from Whisper.
         */
        fun voicedSeconds(samples: FloatArray, sampleRate: Int, config: Config = Config(), minDB: Float = config.minDB): Double {
            val frame = max(1, (config.frame * sampleRate).toInt())
            val minLag = (sampleRate / config.maxPitchHz).toInt()
            val maxLag = (sampleRate / config.minPitchHz).toInt()
            val window = max(frame, 2 * maxLag + frame / 2)
            val scratch = FloatArray(window)
            var voiced = 0
            var end = frame
            while (end <= samples.size) {
                val start = max(0, end - window)
                val n = end - start
                if (n > maxLag + 32 && levelDB(samples.copyOfRange(end - frame, end)) > minDB) {
                    samples.copyInto(scratch, 0, start, end)
                    if (peakAutocorrelation(scratch, n, minLag, maxLag) >= config.voicing) voiced++
                }
                end += frame
            }
            return voiced * config.frame
        }

        fun levelDB(frame: FloatArray): Float {
            if (frame.isEmpty()) return -100f
            var ms = 0f
            for (v in frame) ms += v * v
            ms /= frame.size
            return 10 * log10(ms + 1e-10f)
        }

        private fun percentile(values: List<Float>, p: Double): Float {
            if (values.isEmpty()) return -100f
            val sorted = values.sorted()
            return sorted[min(sorted.size - 1, ((sorted.size - 1) * p).toInt())]
        }

        fun toFloats(pcm: ShortArray): FloatArray = FloatArray(pcm.size) { pcm[it] / 32768f }

        /** Float samples to 16-bit PCM, rounded half away from zero and clamped (as the Swift buffer helper) */
        fun toPcm16(samples: FloatArray): ShortArray = ShortArray(samples.size) {
            val v = samples[it] * 32768
            val r = if (v >= 0) floor(v + 0.5f) else -floor(-v + 0.5f)
            max(-32768f, min(32767f, r)).toInt().toShort()
        }

        /** Little-endian PCM16 bytes to samples */
        fun pcm16FromBytes(bytes: ByteArray): ShortArray = ShortArray(bytes.size / 2) {
            ((bytes[2 * it].toInt() and 0xFF) or (bytes[2 * it + 1].toInt() shl 8)).toShort()
        }
    }
}

/** Fixed-capacity ring of floats: append overwrites the oldest, no reallocation */
internal class Ring(capacity: Int) {
    private val storage = FloatArray(max(1, capacity))
    private var head = 0
    var count = 0
        private set

    fun append(x: Float) {
        storage[head] = x
        head = (head + 1) % storage.size
        count = min(count + 1, storage.size)
    }

    fun append(xs: FloatArray) {
        for (x in xs) append(x)
    }

    fun removeAll() {
        head = 0
        count = 0
    }

    /** Appends the newest [n] values, oldest first */
    fun appendSuffix(n: Int, out: FloatList) {
        val k = min(n, count)
        var i = (head - k + storage.size) % storage.size
        repeat(k) {
            out.add(storage[i])
            i = (i + 1) % storage.size
        }
    }

    /** Writes all values, oldest first, to the start of [dst] */
    fun copyInOrder(dst: FloatArray) {
        var i = (head - count + storage.size) % storage.size
        for (j in 0 until count) {
            dst[j] = storage[i]
            i = (i + 1) % storage.size
        }
    }

    /** Two percentiles (0…1) of the values, sorted once in [scratch] */
    fun percentiles(p: Double, q: Double, scratch: FloatArray): Pair<Float, Float> {
        if (count == 0) return -100f to -100f
        copyInOrder(scratch)
        val n = count
        scratch.sort(0, n)
        return scratch[min(n - 1, ((n - 1) * p).toInt())] to scratch[min(n - 1, ((n - 1) * q).toInt())]
    }
}

/** Growable float buffer without boxing */
internal class FloatList(initial: Int = 1024) {
    private var data = FloatArray(initial)
    var size = 0
        private set

    fun add(x: Float) {
        if (size == data.size) data = data.copyOf(data.size * 2)
        data[size++] = x
    }

    fun addAll(xs: FloatArray) {
        if (size + xs.size > data.size) data = data.copyOf(max(data.size * 2, size + xs.size))
        xs.copyInto(data, size)
        size += xs.size
    }

    fun clear() { size = 0 }

    fun toArray(): FloatArray = data.copyOf(size)
}
