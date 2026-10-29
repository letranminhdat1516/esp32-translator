package vn.cicca.livetranslator.engine

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What keeps a conversation alive: the audio session (router) and the foreground service */
interface ConversationForeground {
    /** Throws when the service cannot start (e.g. ForegroundServiceStartNotAllowedException) */
    fun start()
    fun stop()
}

/** Shows the system permission dialog; the answer comes back through [Permissions.onRequestPermissionsResult] */
fun interface PermissionRequester {
    fun request(permissions: Array<String>, requestCode: Int)
}

/** Runtime permissions, asked through the app's activity (VoiceEngineModule sets [requester]) */
class Permissions(private val context: Context) {
    @Volatile var requester: PermissionRequester? = null
    private var pending: CompletableDeferred<Boolean>? = null

    fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Asks for the missing ones; true when all are granted */
    suspend fun ensure(permissions: List<String>): Boolean {
        val missing = permissions.filterNot { granted(it) }
        if (missing.isEmpty()) return true
        val r = requester ?: return false
        val result = CompletableDeferred<Boolean>()
        pending = result
        withContext(Dispatchers.Main) { r.request(missing.toTypedArray(), REQUEST) }
        return result.await() && missing.all { granted(it) }
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST) return false
        pending?.complete(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pending = null
        return true
    }

    companion object {
        private const val REQUEST = 0x7e1

        /** What a conversation needs: the mic; Bluetooth for the headset (12+); the notification (13+) */
        fun conversation(): List<String> = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

/**
 * The Android voice engine behind the VoiceEngine TurboModule ([VoiceEngineModule]): mic → [VoiceGate] → home
 * recognizer, board audio → the other language's recognizer, ML Kit translation, TTS, downloads and the audio
 * session. The home language always comes from the caller (`capabilities(home)`, the pair).
 *
 * Errors are [EngineException]s with the EngineError names (translateFailed, notReady, downloadFailed).
 */
class NativeVoiceEngine(
    private val context: Context,
    private val events: EngineEventSink,
    private val recognizers: RecognizerCatalog = DeviceRecognizers(context),
    foreground: ConversationForeground? = null,
) {
    /** The audio session and the foreground service, up while a conversation runs */
    private val foreground: ConversationForeground = foreground ?: object : ConversationForeground {
        override fun start() {
            VoiceService.status = { status() }
            router.start()
            try {
                VoiceService.start(context)
            } catch (e: Exception) {
                router.stop()
                throw e
            }
        }

        override fun stop() {
            router.stop()
            VoiceService.stop(context)
            VoiceService.status = { "idle" }
        }
    }

    val isRunning: Boolean get() = synchronized(lock) { session != null }
    val runningGeneration: Long? get() = synchronized(lock) { session?.pair?.generation }

    val permissions = Permissions(context)
    private val translator = MlKitTranslator({ context.isOnline() })
    private val speaker = Speaker(context, events)
    private val downloads = Downloads(context, events, translator, recognizers as? SpeechModelDownloader
        ?: SpeechModelDownloader { throw EngineErrors.downloadFailed("no speech model download on this phone") })
    private val gate = VoiceGate(log = { Log.i("VoiceGate", it) })
    private val router = AudioRouter(context, events, onRoute = { route ->
        gate.resetWearerLevel()
        speaker.setHeadsetRoute(route == AudioRoute.HEADSET)
    })

    private val lock = Any()
    private var session: Session? = null
    /** Bumped by every start() and stop(); a start whose token is no longer current gives up */
    private var startToken = 0L
    private var foregroundUp = false

    private inner class Session(
        val pair: PairMsg,
        val mine: UtteranceRecognizer,
        val theirs: UtteranceRecognizer,
        startElapsed: Long,
    ) {
        val mic = MicCapture(gate, events, object : UtteranceSink {
            override fun audio(pcm: ShortArray) = mine.audio(pcm, MicCapture.SAMPLE_RATE)
            override fun ended(startMs: Long, endMs: Long) = mine.endUtterance(startMs, endMs)
        }, clock = { MicCapture.since(startElapsed) })
        @Volatile var theirSamples = 0L
        /** What JS last asked with micOn */
        @Volatile var micOn = false

        fun close() {
            mic.stop()
            mine.close()
            theirs.close()
        }
    }

    /** Runs on an IO thread (OS and ML Kit queries can be slow); [home] is the mic side's language */
    suspend fun capabilities(home: String): CapabilitiesMsg = withContext(Dispatchers.IO) {
        val translatable = translator.translatable()
        val kinds = recognizers.kinds(home, translatable)
        CapabilitiesMsg(
            recognizers = kinds.map { (language, list) -> RecognizerEntryMsg(language, list) },
            translatable = translatable,
            vietnameseVoice = speaker.hasVoice(home),
        )
    }

    /** Runs on an IO thread, like [capabilities] */
    suspend fun missing(pair: PairMsg): List<MissingMsg> = withContext(Dispatchers.IO) {
        MissingItems.compute(
            translation = translator.missing(pair.home, pair.other),
            speechModels = recognizers.speechModelsMissing(pair),
            vietnameseVoice = speaker.hasVoice(pair.home),
            home = pair.home,
        )
    }

    suspend fun download(item: MissingMsg) = withContext(Dispatchers.IO) { downloads.download(item) }

    /**
     * Starts (or switches to) a conversation. Idempotent for the running pair. Starts are ordered by
     * [startToken]: stop() and every later start() bump it, and a start that finds its token stale after
     * a suspension closes what it built and returns. The foreground (audio session + service) is brought up
     * once, before the session is published; if it fails nothing is left half-started, so the next
     * start() retries. Switching pairs keeps the foreground up and carries the mic state over.
     */
    suspend fun start(pair: PairMsg, recognizerX: String, hints: List<String>) {
        val token = synchronized(lock) {
            // Idempotent: the same pair and generation is already running
            if (session?.pair == pair) return
            ++startToken
        }
        if (!permissions.ensure(Permissions.conversation())) {
            throw EngineErrors.notReady("microphone permission denied")
        }
        if (synchronized(lock) { token != startToken }) return
        val built = build(pair, recognizerX, hints)
        val old: Session?
        synchronized(lock) {
            if (token != startToken) {
                built.close()
                Log.i(TAG, "start gen ${pair.generation} superseded")
                return
            }
            if (!foregroundUp) {
                try {
                    foreground.start()
                } catch (e: Exception) {
                    built.close()
                    throw EngineErrors.notReady("could not start the conversation service: ${e.message}")
                }
                foregroundUp = true
            }
            old = session
            session = built
        }
        Log.i(TAG, "started ${pair.home}↔${pair.other} gen ${pair.generation} with $recognizerX")
        if (old != null) {
            val micWasOn = old.micOn
            old.close()
            if (micWasOn) {
                try { micOn(true) } catch (e: EngineException) { Log.w(TAG, "mic after the switch: ${e.message}") }
            }
        }
    }

    /** The session's recognizers (IO thread); throws `notReady` when one cannot run */
    private suspend fun build(pair: PairMsg, recognizerX: String, hints: List<String>): Session {
        val startElapsed = SystemClock.elapsedRealtime()
        val clock = { MicCapture.since(startElapsed) }
        return withContext(Dispatchers.IO) {
            val generation = pair.generation
            val mineKind = recognizers.mineKind(pair.home, recognizerX)
            speaker.setLanguage(pair.home) // speech output in the pair's home language
            val mine = recognizers.create(
                RecognizerRequest(mineKind, pair.home, hints, mine = true, clock = clock, onResult = { r ->
                    events.mine(
                        MineMsg(if (r.final) MineKind.FINAL_TEXT else MineKind.PARTIAL, r.text, r.startMs, r.endMs),
                    )
                }, onSpeech = { events.gate(it) }),
            )
            val theirs = try {
                recognizers.create(
                    RecognizerRequest(recognizerX, pair.other, hints, mine = false, clock = clock, onResult = { r ->
                        if (r.final) events.theirs(TheirsMsg(r.text, r.confidence, generation))
                    }),
                )
            } catch (e: Exception) {
                mine.close()
                throw e
            }
            Log.i(TAG, "recognizers: mine $mineKind (${pair.home}), theirs $recognizerX (${pair.other})")
            Session(pair, mine, theirs, startElapsed)
        }
    }

    /** Idempotent; also cancels a start still in progress */
    fun stop() {
        val s: Session?
        val wasUp: Boolean
        synchronized(lock) {
            startToken++
            s = session
            session = null
            wasUp = foregroundUp
            foregroundUp = false
        }
        s?.close()
        if (wasUp) foreground.stop()
        if (s != null || wasUp) Log.i(TAG, "stopped")
    }

    /** Throws `notReady` when the mic cannot start (JS also gets audioSession(interrupted)) */
    fun micOn(on: Boolean) {
        val s = synchronized(lock) { session } ?: return
        when {
            // An OS recognizer below Android 13 listens to the mic itself
            s.mine.ownsMic -> s.mine.listen(on)
            on -> s.mic.start() // throws notReady: micOn then stays false
            else -> s.mic.stop()
        }
        s.micOn = on
    }

    /** Board PCM as 16-bit little-endian mono bytes */
    fun feedTheirAudio(pcm16le: ByteArray, sampleRate: Long) =
        feedTheirAudio(VoiceGate.pcm16FromBytes(pcm16le), sampleRate.toInt())

    /** Board PCM, mono samples; dropped when no conversation runs */
    fun feedTheirAudio(pcm: ShortArray, sampleRate: Int) {
        val s = synchronized(lock) { session } ?: return
        s.theirSamples += pcm.size
        s.theirs.audio(pcm, sampleRate)
    }

    suspend fun translate(text: String, from: String, to: String): String =
        withContext(Dispatchers.IO) { translator.translate(text, from, to) }

    fun speak(text: String, id: Long) = speaker.speak(text, id)

    fun stopSpeaking() = speaker.stop()

    fun setHints(hints: List<String>) {
        val s = synchronized(lock) { session } ?: return
        s.mine.setHints(hints)
        s.theirs.setHints(hints)
    }

    fun openTtsSettings() = Speaker.openTtsSettings(context)

    /** Ends the engine for good (the module's invalidate()): the session, TTS, ML Kit and the Whisper model */
    fun shutdown() {
        stop()
        speaker.shutdown()
        translator.close()
        recognizers.shutdown()
    }

    private fun status(): String {
        val s = synchronized(lock) { session } ?: return "idle"
        return "mic ${if (s.mic.isRunning) "on" else "off"} ${s.mic.framesRead / MicCapture.SAMPLE_RATE}s read, " +
            "peak ${"%.0f".format(s.mic.peakDB)} dB, " +
            "gate ${if (gate.isOpen) "open" else "closed"} (background ${"%.0f".format(gate.floorDB)} dB), " +
            "route ${router.route}, board audio ${s.theirSamples / MicCapture.SAMPLE_RATE}s" +
            (if (s.mic.silenced) ", mic SILENCED by the system" else "") +
            (s.mic.lastError?.let { ", mic error: $it" } ?: "")
    }

    private companion object {
        const val TAG = "VoiceEngine"
    }
}
