package vn.cicca.livetranslator.engine

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import java.util.Locale

/**
 * The recognizers of this phone (P3): what [capabilities] reports and what a session gets.
 * See [RecognizerChoice] for the rules.
 */
class DeviceRecognizers(
    private val context: Context,
    private val whisper: WhisperSupport? = DeviceWhisper(context) { context.isOnline() },
) : RecognizerCatalog, SpeechModelDownloader {
    private val api = Build.VERSION.SDK_INT
    @Volatile private var onDeviceLanguages: Set<String> = emptySet()

    init {
        if (api >= RecognizerChoice.FED_AUDIO_API) queryOnDeviceLanguages()
    }

    fun choice() = RecognizerChoice(
        api = api,
        onDeviceLanguages = onDeviceLanguages,
        onlineAvailable = SpeechRecognizer.isRecognitionAvailable(context),
        whisperAvailable = whisper?.libraryLoaded == true,
    )

    /** The Whisper model is the only speech model the app downloads */
    override suspend fun download(progress: (Double) -> Unit) {
        val d = whisper as? SpeechModelDownloader ?: throw EngineErrors.downloadFailed("no Whisper on this phone")
        d.download(progress)
    }

    override fun kinds(home: String, languages: List<String>): Map<String, List<String>> {
        val c = choice()
        return (languages + home).distinct().associateWith { c.kinds(it, fromMic = it == home) }
            .filterValues { it.isNotEmpty() }
    }

    override fun speechModelsMissing(pair: PairMsg): List<String> {
        val w = whisper ?: return emptyList()
        if (!w.libraryLoaded || w.modelPresent()) return emptyList()
        val c = choice()
        // Whisper is needed where no on-device OS recognizer can serve the language
        return listOf(pair.home, pair.other).distinct()
            .filter { Kinds.OS_ON_DEVICE !in c.kinds(it, fromMic = it == pair.home) }
    }

    override fun create(request: RecognizerRequest): UtteranceRecognizer {
        val c = choice()
        val offered = c.kinds(request.language, fromMic = request.mine)
        val fed = request.kind == Kinds.WHISPER || c.canFeed(request.kind)
        return when (request.kind) {
            Kinds.WHISPER -> {
                val w = whisper
                if (w == null || Kinds.WHISPER !in offered) throw EngineErrors.notReady("no Whisper for ${request.language}")
                w.create(request)
            }
            Kinds.OS_ON_DEVICE, Kinds.OS_ONLINE -> {
                if (request.kind !in offered || (!request.mine && !fed)) {
                    throw EngineErrors.notReady(
                        "${request.kind} for ${request.language} is not available" +
                            if (!fed) " (Android recognizers take board audio only from Android 13)" else "",
                    )
                }
                OsRecognizer(context, request, onDevice = request.kind == Kinds.OS_ON_DEVICE, fed = fed)
            }
            else -> throw EngineErrors.notReady("unknown recognizer ${request.kind}")
        }
    }

    override fun mineKind(home: String, recognizerX: String): String = choice().mine(home, recognizerX)

    override fun shutdown() {
        whisper?.shutdown()
    }

    /** Installed on-device languages (API 33+), asked once at launch */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun queryOnDeviceLanguages() {
        Handler(Looper.getMainLooper()).post {
            if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return@post
            val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            r.checkRecognitionSupport(
                Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
                context.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        onDeviceLanguages = support.installedOnDeviceLanguages
                            .map { Locale.forLanguageTag(it).language }.toSet()
                        Log.i(TAG, "on-device languages: $onDeviceLanguages")
                        r.destroy()
                    }

                    override fun onError(error: Int) {
                        Log.w(TAG, "on-device language query failed: $error")
                        r.destroy()
                    }
                },
            )
        }
    }

    private companion object {
        const val TAG = "DeviceRecognizers"
    }
}

/** What the catalog needs from Whisper (E6) */
interface WhisperSupport {
    val libraryLoaded: Boolean
    fun modelPresent(): Boolean
    fun create(request: RecognizerRequest): UtteranceRecognizer
    /** Releases the model (engine shutdown) */
    fun shutdown() {}
}
