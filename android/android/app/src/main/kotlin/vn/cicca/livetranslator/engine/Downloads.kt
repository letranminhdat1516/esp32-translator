package vn.cicca.livetranslator.engine

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.speech.tts.TextToSpeech
import android.util.Log

/** A download the engine can run for a [MissingKind.SPEECH_MODEL] item (the Whisper model) */
fun interface SpeechModelDownloader {
    suspend fun download(progress: (Double) -> Unit)
}

/**
 * Runs `download(item)` for every kind of missing item and reports it as `download` events (R3):
 * progress 0 when it starts, progress 1 and done when it finishes, or done with the error message when it
 * fails, in which case the call also throws `downloadFailed`.
 *
 * - translation: the ML Kit models of the pair (no fine progress in ML Kit: 0, then 1)
 * - speechModel: the Whisper model through [speechModel] (SHA-256 checked by the model store)
 * - ttsVoice: Android cannot install a voice for an app; this opens the system voice download screen
 *   and reports done, so the app re-checks `missing()` when the user comes back
 */
class Downloads(
    private val context: Context,
    private val events: EngineEventSink,
    private val translator: MlKitTranslator,
    private val speechModel: SpeechModelDownloader,
) {
    suspend fun download(item: MissingMsg) {
        var last = 0.0
        val report = { p: Double ->
            last = p
            events.download(DownloadMsg(item, progress = p, done = false))
        }
        try {
            when (item.kind) {
                MissingKind.TRANSLATION -> translator.download(
                    item.from ?: HOME_LANGUAGE,
                    item.to ?: item.language,
                    report,
                )
                MissingKind.SPEECH_MODEL -> speechModel.download(report)
                MissingKind.TTS_VOICE -> {
                    report(0.0)
                    context.startActivity(
                        Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
            }
        } catch (e: Exception) {
            val error = (e as? FlutterError)?.message ?: e.message ?: e.javaClass.simpleName
            Log.w(TAG, "download $item failed: $error")
            events.download(DownloadMsg(item, progress = last, done = true, error = error))
            throw e as? FlutterError ?: EngineErrors.downloadFailed(error)
        }
        Log.i(TAG, "download $item done")
        events.download(DownloadMsg(item, progress = 1.0, done = true))
    }

    private companion object {
        const val TAG = "Downloads"
    }
}

/** True when the phone has a validated internet connection */
fun Context.isOnline(): Boolean {
    val cm = getSystemService(ConnectivityManager::class.java) ?: return false
    val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
    return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
}

/** What `missing(pair)` reports, in the order the readiness view lists it */
object MissingItems {
    /**
     * [translation]: the ML Kit item for the pair, if any; [speechModels]: languages of the pair that need
     * the Whisper model and do not have it; [vietnameseVoice]: a Vietnamese TTS voice is installed.
     */
    fun compute(translation: List<MissingMsg>, speechModels: List<String>, vietnameseVoice: Boolean): List<MissingMsg> =
        speechModels.map { MissingMsg(MissingKind.SPEECH_MODEL, it) } +
            translation +
            (if (vietnameseVoice) emptyList() else listOf(MissingMsg(MissingKind.TTS_VOICE, HOME_LANGUAGE)))
}
