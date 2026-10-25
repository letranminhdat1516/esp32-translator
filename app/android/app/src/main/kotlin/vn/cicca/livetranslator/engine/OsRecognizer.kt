package vn.cicca.livetranslator.engine

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Android's own recognizers (P3): on-device (`createOnDeviceSpeechRecognizer`, API 33+ here) and the
 * default online one (`osOnline`, created only when Dart asks for it: the consent is held in Dart).
 *
 * Two ways to get audio:
 * - mic mode (mine below API 33): the recognizer listens to the mic itself, restarted after every result
 *   so it keeps listening while `micOn(true)`; speech start/end drive the gate event;
 * - fed mode (API 33+): each utterance's PCM goes through a pipe as EXTRA_AUDIO_SOURCE; closing the pipe
 *   at the end of the utterance makes the recognizer finalize.
 *
 * SpeechRecognizer must be used on the main thread; every call here hops to it.
 */
class OsRecognizer(
    context: Context,
    private val request: RecognizerRequest,
    private val onDevice: Boolean,
    private val fed: Boolean,
) : UtteranceRecognizer {
    private val main = Handler(Looper.getMainLooper())
    private val appContext = context.applicationContext
    private val locale = Locale.forLanguageTag(request.language).toLanguageTag()
    private var recognizer: SpeechRecognizer? = null
    @Volatile private var hints = request.hints
    @Volatile private var closed = false

    // Mic mode
    @Volatile private var listening = false
    private var speechStart = 0L
    private var speechEnd = 0L

    // Fed mode
    private val writer = Executors.newSingleThreadExecutor()
    private var pipeOut: OutputStream? = null

    override val ownsMic: Boolean get() = !fed

    init {
        main.post { recognizer = create() }
    }

    private fun create(): SpeechRecognizer {
        val r = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        } else {
            SpeechRecognizer.createSpeechRecognizer(appContext)
        }
        r.setRecognitionListener(listener)
        Log.i(TAG, "${request.kind} recognizer for ${request.language} (${if (fed) "fed" else "mic"})")
        return r
    }

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        if (onDevice) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && hints.isNotEmpty()) {
            putExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(hints))
        }
    }

    // Mic mode

    override fun listen(on: Boolean) {
        if (fed) return
        main.post {
            if (closed) return@post
            listening = on
            if (on) startListening() else recognizer?.cancel()
        }
    }

    private fun startListening() {
        if (!listening || closed) return
        recognizer?.startListening(intent())
    }

    private fun restart(delayMs: Long) {
        main.postDelayed({ startListening() }, delayMs)
    }

    // Fed mode

    override fun audio(pcm: ShortArray, sampleRate: Int) {
        if (!fed || closed) return
        val bytes = ByteBuffer.allocate(pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        bytes.asShortBuffer().put(pcm)
        writer.execute {
            val out = pipeOut ?: openUtterance(sampleRate) ?: return@execute
            try {
                out.write(bytes.array())
            } catch (e: IOException) {
                Log.w(TAG, "pipe write: ${e.message}")
            }
        }
    }

    /** Starts a recognition reading from a new pipe (writer thread) */
    private fun openUtterance(sampleRate: Int): OutputStream? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        val (read, write) = ParcelFileDescriptor.createPipe()
        val out = ParcelFileDescriptor.AutoCloseOutputStream(write)
        pipeOut = out
        main.post {
            val i = intent().apply {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
            }
            recognizer?.startListening(i)
            read.close() // the recognizer holds its own duplicate
        }
        return out
    }

    override fun endUtterance(startMs: Long, endMs: Long) {
        if (!fed) return
        speechStart = startMs
        speechEnd = endMs
        writer.execute {
            try { pipeOut?.close() } catch (_: IOException) {}
            pipeOut = null
        }
    }

    override fun setHints(hints: List<String>) {
        this.hints = hints
    }

    override fun close() {
        closed = true
        writer.execute {
            try { pipeOut?.close() } catch (_: IOException) {}
            pipeOut = null
        }
        writer.shutdown()
        main.post {
            listening = false
            recognizer?.destroy()
            recognizer = null
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            Log.d(TAG, "ready")
        }

        override fun onBeginningOfSpeech() {
            speechStart = request.clock()
            if (!fed) request.onSpeech(true)
        }

        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            speechEnd = request.clock()
            if (!fed) request.onSpeech(false)
        }

        override fun onError(error: Int) {
            Log.w(TAG, "${request.kind} ${request.language} error $error (${errorName(error)})")
            lastError = error
            if (!fed && listening && !closed) {
                // Silence and no-match are routine while listening continuously; back off on the rest
                val routine = error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
                if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) recognizer?.cancel()
                restart(if (routine) 100 else 2_000)
            }
        }

        override fun onResults(results: Bundle) {
            emit(results, final = true)
            if (!fed) restart(0)
        }

        override fun onPartialResults(partialResults: Bundle) {
            emit(partialResults, final = false)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    @Volatile var lastError: Int? = null
        private set

    private fun emit(bundle: Bundle, final: Boolean) {
        val text = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim().orEmpty()
        if (text.isEmpty()) return
        val confidence = bundle.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)?.firstOrNull()
            ?.takeIf { it >= 0 }?.toDouble()
        val end = if (final) maxOf(speechEnd, speechStart) else request.clock()
        request.onResult(Recognized(text, final, confidence, speechStart, end))
    }

    companion object {
        private const val TAG = "OsRecognizer"

        fun errorName(error: Int) = when (error) {
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network timeout"
            SpeechRecognizer.ERROR_NETWORK -> "network"
            SpeechRecognizer.ERROR_AUDIO -> "audio"
            SpeechRecognizer.ERROR_SERVER -> "server"
            SpeechRecognizer.ERROR_CLIENT -> "client"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "no match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permissions"
            else -> "other"
        }
    }
}
