package vn.cicca.livetranslator.engine

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** whisper.cpp through JNI (`whisper_jni.cpp`), arm64-v8a only */
internal object WhisperNative {
    val loaded: Boolean = try {
        System.loadLibrary("whisper_jni")
        true
    } catch (e: UnsatisfiedLinkError) {
        Log.w("WhisperNative", "whisper.cpp not available on this ABI: ${e.message}")
        false
    }

    external fun init(modelPath: String): Long
    external fun free(handle: Long)
    external fun systemInfo(): String
    external fun transcribe(handle: Long, samples: FloatArray, language: String, prompt: String?, threads: Int): Array<WhisperSegment>?
}

/**
 * The Whisper model, shared by both sides of a conversation. Loaded once (after its SHA-256 check);
 * utterances are transcribed one at a time on one worker thread, in arrival order.
 */
class WhisperModel(val store: ModelStore, private val threads: Int = 4) {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "whisper") }
    @Volatile private var handle = 0L

    /** Result of one utterance; [rtf] = processing time / audio time */
    data class Transcript(val text: String?, val segments: List<WhisperSegment>, val audioSeconds: Double, val seconds: Double) {
        val rtf: Double get() = if (audioSeconds > 0) seconds / audioSeconds else 0.0
        /** Mean token probability of the speech segments (reported as the result's confidence) */
        val confidence: Double?
            get() = segments.filter { it.noSpeechProb <= HallucinationFilter.NO_SPEECH_THRESHOLD }
                .takeIf { it.isNotEmpty() }?.map { it.tokenProb.toDouble() }?.average()
    }

    /** Loads the model if needed (worker thread); false when it is missing or fails its SHA-256 check */
    @Synchronized
    fun load(): Boolean {
        if (handle != 0L) return true
        if (!WhisperNative.loaded || !store.verified()) return false
        val started = SystemClock.elapsedRealtime()
        handle = WhisperNative.init(store.file.absolutePath)
        Log.i(TAG, "model ${store.spec.fileName} loaded in ${SystemClock.elapsedRealtime() - started} ms: ${WhisperNative.systemInfo()}")
        return handle != 0L
    }

    /** Transcribes 16 kHz mono samples (blocking; call from [submit]) */
    fun transcribe(samples: FloatArray, language: String, prompt: String?): Transcript {
        val audio = samples.size / SAMPLE_RATE.toDouble()
        // Whisper hallucinates on silence and noise, and whisper.cpp's no_speech_prob stays near 0 for them
        // (measured: "you" on digital zeros, "Này, đúng rồi." on -45 dB noise). Only utterances with voiced
        // speech in them (the gate's pitch test) are transcribed.
        val voiced = VoiceGate.voicedSeconds(samples, SAMPLE_RATE)
        if (voiced < MIN_VOICED_SECONDS) {
            Log.i(TAG, "whisper $language: %.1f s without speech skipped (%.2f s voiced)".format(audio, voiced))
            return Transcript(null, emptyList(), audio, 0.0)
        }
        if (!load()) return Transcript(null, emptyList(), audio, 0.0)
        val started = SystemClock.elapsedRealtime()
        val segments = WhisperNative.transcribe(handle, samples, language, prompt, threads)?.toList().orEmpty()
        val seconds = (SystemClock.elapsedRealtime() - started) / 1000.0
        val t = Transcript(HallucinationFilter.filter(segments), segments, audio, seconds)
        Log.i(
            TAG,
            "whisper $language: %.1f s audio in %.2f s, real-time factor %.2f, %d segment(s) → %s".format(
                audio, seconds, t.rtf, segments.size, t.text?.let { "\"$it\"" } ?: "(dropped)",
            ),
        )
        return t
    }

    fun submit(task: () -> Unit) {
        worker.execute {
            try { task() } catch (e: Exception) { Log.e(TAG, "transcription failed", e) }
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        /** Utterances with less voiced speech than this are not transcribed */
        const val MIN_VOICED_SECONDS = 0.2
        private const val TAG = "Whisper"
    }
}

/**
 * Whisper on utterances (P3, R12): no partials, one `final` per utterance. The mic side's utterances are
 * cut by the voice gate; the board side's by board silence: the board stops streaming when nobody speaks,
 * so a pause of [boardPauseMs] in the audio ends the utterance (as the Swift app's phrase-end watcher).
 * Utterances are capped at [maxSeconds] (Whisper's 30 s window). Hints become the initial prompt.
 */
class WhisperRecognizer(
    private val model: WhisperModel,
    private val request: RecognizerRequest,
    private val boardPauseMs: Long = 250,
    private val maxSeconds: Int = 30,
    private val minSeconds: Double = 0.3,
) : UtteranceRecognizer {
    private val lock = Any()
    private val buffer = FloatList(WhisperModel.SAMPLE_RATE * 5)
    @Volatile private var hints = request.hints
    @Volatile private var closed = false
    private var lastAudio = 0L
    private var utteranceStart = -1L
    private var watcher: ScheduledExecutorService? = null
    private var watch: ScheduledFuture<*>? = null

    init {
        if (!request.mine) {
            watcher = Executors.newSingleThreadScheduledExecutor { Thread(it, "board-pause") }.also {
                watch = it.scheduleWithFixedDelay({ checkPause() }, 150, 150, TimeUnit.MILLISECONDS)
            }
        }
    }

    override fun audio(pcm: ShortArray, sampleRate: Int) {
        if (closed) return
        val samples = resample(VoiceGate.toFloats(pcm), sampleRate)
        val full: FloatArray?
        synchronized(lock) {
            if (utteranceStart < 0) utteranceStart = request.clock()
            buffer.addAll(samples)
            lastAudio = SystemClock.elapsedRealtime()
            full = if (buffer.size >= maxSeconds * WhisperModel.SAMPLE_RATE) take() else null
        }
        full?.let { run(it, utteranceStart, request.clock()) }
    }

    override fun endUtterance(startMs: Long, endMs: Long) {
        val samples = synchronized(lock) { take() } ?: return
        run(samples, startMs, endMs)
    }

    private fun checkPause() {
        val samples: FloatArray?
        val start: Long
        synchronized(lock) {
            if (buffer.size == 0 || SystemClock.elapsedRealtime() - lastAudio < boardPauseMs) return
            start = utteranceStart
            samples = take()
        }
        samples?.let { run(it, start, request.clock()) }
    }

    /** The buffered utterance, cleared (call with [lock] held) */
    private fun take(): FloatArray? {
        if (buffer.size == 0) return null
        val out = buffer.toArray()
        buffer.clear()
        utteranceStart = -1
        return out
    }

    private fun run(samples: FloatArray, startMs: Long, endMs: Long) {
        if (samples.size < minSeconds * WhisperModel.SAMPLE_RATE) return
        val prompt = hints.takeIf { it.isNotEmpty() }?.joinToString(", ")
        model.submit {
            if (closed) return@submit
            val t = model.transcribe(samples, request.language, prompt)
            val text = t.text ?: return@submit
            if (!closed) request.onResult(Recognized(text, final = true, confidence = t.confidence, startMs = startMs, endMs = endMs))
        }
    }

    override fun setHints(hints: List<String>) {
        this.hints = hints
    }

    override fun close() {
        closed = true
        watch?.cancel(false)
        watcher?.shutdown()
        synchronized(lock) { buffer.clear() }
    }

    companion object {
        /** Linear resampling to 16 kHz (the board and the mic already deliver 16 kHz) */
        fun resample(x: FloatArray, rate: Int): FloatArray {
            if (rate == WhisperModel.SAMPLE_RATE || x.isEmpty()) return x
            val n = (x.size.toLong() * WhisperModel.SAMPLE_RATE / rate).toInt()
            return FloatArray(n) { i ->
                val pos = i.toDouble() * rate / WhisperModel.SAMPLE_RATE
                val j = pos.toInt().coerceAtMost(x.size - 1)
                val k = (j + 1).coerceAtMost(x.size - 1)
                val f = (pos - j).toFloat()
                x[j] * (1 - f) + x[k] * f
            }
        }
    }
}

/** Whisper for [DeviceRecognizers]: the model store and one shared model */
class DeviceWhisper(context: Context, isOnline: () -> Boolean) : WhisperSupport, SpeechModelDownloader {
    val store = ModelStore(File(context.filesDir, "models"), isOnline = isOnline)
    val model = WhisperModel(store)

    override val libraryLoaded: Boolean get() = WhisperNative.loaded

    override fun modelPresent(): Boolean = store.present()

    override fun create(request: RecognizerRequest): UtteranceRecognizer {
        // The SHA-256 check runs here, before the model is used; a bad file is deleted and reported missing
        if (!model.load()) throw EngineErrors.notReady("speech model missing or failed its check")
        return WhisperRecognizer(model, request)
    }

    override suspend fun download(progress: (Double) -> Unit) = store.download(progress)
}
