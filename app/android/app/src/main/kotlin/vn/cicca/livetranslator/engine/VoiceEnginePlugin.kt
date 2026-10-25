package vn.cicca.livetranslator.engine

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Registers the Android [VoiceEngineApi] on the Flutter engine (added in MainActivity). The engine lives as
 * long as the Flutter engine; [VoiceService] keeps the process in the foreground while a conversation runs.
 */
class VoiceEnginePlugin : FlutterPlugin, ActivityAware {
    private var engine: NativeVoiceEngine? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        val e = NativeVoiceEngine(binding.applicationContext, PigeonEventSink(binding.binaryMessenger))
        engine = e
        VoiceEngineApi.setUp(binding.binaryMessenger, e)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VoiceEngineApi.setUp(binding.binaryMessenger, null)
        engine?.shutdown()
        engine = null
        this.binding = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        engine?.permissions?.let {
            it.activity = binding.activity
            binding.addRequestPermissionsResultListener(it)
        }
    }

    override fun onDetachedFromActivity() {
        engine?.permissions?.let {
            activityBinding?.removeRequestPermissionsResultListener(it)
            it.activity = null
        }
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
}

/** Runtime permissions, asked through the Flutter activity */
class Permissions(private val context: Context) : PluginRegistry.RequestPermissionsResultListener {
    @Volatile var activity: Activity? = null
    private var pending: CompletableDeferred<Boolean>? = null

    fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Asks for the missing ones; true when all are granted */
    suspend fun ensure(permissions: List<String>): Boolean {
        val missing = permissions.filterNot { granted(it) }
        if (missing.isEmpty()) return true
        val a = activity ?: return false
        val result = CompletableDeferred<Boolean>()
        pending = result
        withContext(Dispatchers.Main) { a.requestPermissions(missing.toTypedArray(), REQUEST) }
        return result.await() && missing.all { granted(it) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
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
 * The Android voice engine behind the pigeon [VoiceEngineApi]: mic → [VoiceGate] → Vietnamese recognizer,
 * board audio → the other language's recognizer, ML Kit translation, TTS, downloads and the audio session.
 *
 * Errors reach Dart as [FlutterError] with the EngineError names (translateFailed, notReady, downloadFailed).
 */
class NativeVoiceEngine(
    private val context: Context,
    private val events: EngineEventSink,
    private val recognizers: RecognizerCatalog = DeviceRecognizers(context),
) : VoiceEngineApi {
    val permissions = Permissions(context)
    private val translator = MlKitTranslator({ context.isOnline() })
    private val speaker = Speaker(context, events)
    private val downloads = Downloads(context, events, translator, recognizers as? SpeechModelDownloader
        ?: SpeechModelDownloader { throw EngineErrors.downloadFailed("no speech model download on this build") })
    private val gate = VoiceGate(log = { Log.i("VoiceGate", it) })
    private val router = AudioRouter(context, events, onRoute = { route ->
        gate.resetWearerLevel()
        speaker.setHeadsetRoute(route == AudioRoute.HEADSET)
    })

    private val lock = Any()
    private var session: Session? = null

    private inner class Session(val pair: PairMsg, val mine: UtteranceRecognizer, val theirs: UtteranceRecognizer) {
        val startElapsed = SystemClock.elapsedRealtime()
        val mic = MicCapture(gate, events, object : UtteranceSink {
            override fun audio(pcm: ShortArray) = mine.audio(pcm, MicCapture.SAMPLE_RATE)
            override fun ended(startMs: Long, endMs: Long) = mine.endUtterance(startMs, endMs)
        }, clock = { MicCapture.since(startElapsed) })
        @Volatile var theirSamples = 0L
    }

    override fun capabilities(): CapabilitiesMsg {
        val translatable = translator.translatable()
        val kinds = recognizers.kinds(translatable)
        return CapabilitiesMsg(
            recognizers = kinds.map { (language, list) -> RecognizerEntryMsg(language, list) },
            translatable = translatable,
            vietnameseVoice = speaker.hasVoice(),
        )
    }

    override fun missing(pair: PairMsg): List<MissingMsg> = MissingItems.compute(
        translation = translator.missing(pair.home, pair.other),
        speechModels = recognizers.speechModelsMissing(pair),
        vietnameseVoice = speaker.hasVoice(),
    )

    override suspend fun download(item: MissingMsg) = withContext(Dispatchers.IO) { downloads.download(item) }

    override suspend fun start(pair: PairMsg, recognizerX: String, hints: List<String>) {
        synchronized(lock) {
            val current = session
            // Idempotent: the same pair and generation is already running
            if (current != null && current.pair == pair) return
        }
        if (!permissions.ensure(Permissions.conversation())) {
            throw EngineErrors.notReady("microphone permission denied")
        }
        stop()
        val s = withContext(Dispatchers.IO) {
            val generation = pair.generation
            val mine = recognizers.create(recognizers.mineKind(recognizerX), pair.home, hints) { r ->
                events.mine(
                    MineMsg(if (r.final) MineKind.FINAL_TEXT else MineKind.PARTIAL, r.text, r.startMs, r.endMs),
                )
            }
            val theirs = try {
                recognizers.create(recognizerX, pair.other, hints) { r ->
                    if (r.final) events.theirs(TheirsMsg(r.text, r.confidence, generation))
                }
            } catch (e: Exception) {
                mine.close()
                throw e
            }
            Session(pair, mine, theirs)
        }
        synchronized(lock) { session = s }
        VoiceService.status = { status() }
        VoiceService.start(context)
        router.start()
        Log.i(TAG, "started ${pair.home}↔${pair.other} gen ${pair.generation} with $recognizerX")
    }

    override fun stop() {
        val s = synchronized(lock) { session.also { session = null } } ?: return
        s.mic.stop()
        s.mine.close()
        s.theirs.close()
        router.stop()
        VoiceService.stop(context)
        VoiceService.status = { "idle" }
        Log.i(TAG, "stopped")
    }

    override fun micOn(on: Boolean) {
        val s = synchronized(lock) { session } ?: return
        if (on) s.mic.start() else s.mic.stop()
    }

    override fun feedTheirAudio(pcm16le: ByteArray, sampleRate: Long) {
        val s = synchronized(lock) { session } ?: return
        val pcm = VoiceGate.pcm16FromBytes(pcm16le)
        s.theirSamples += pcm.size
        s.theirs.audio(pcm, sampleRate.toInt())
    }

    override suspend fun translate(text: String, from: String, to: String): String =
        withContext(Dispatchers.IO) { translator.translate(text, from, to) }

    override fun speak(text: String, id: Long) = speaker.speak(text, id)

    override fun stopSpeaking() = speaker.stop()

    override fun setHints(hints: List<String>) {
        val s = synchronized(lock) { session } ?: return
        s.mine.setHints(hints)
        s.theirs.setHints(hints)
    }

    override fun openTtsSettings() = Speaker.openTtsSettings(context)

    fun shutdown() {
        stop()
        speaker.shutdown()
        translator.close()
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
