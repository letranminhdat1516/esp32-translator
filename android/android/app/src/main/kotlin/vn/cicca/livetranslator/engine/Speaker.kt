package vn.cicca.livetranslator.engine

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

/**
 * Vietnamese speech output with the system TextToSpeech (P5). Utterances queue in order; each `speak(id)`
 * produces `ttsStart(id)` when it starts and exactly one `ttsEnd(id)` when it finishes, fails or is stopped.
 *
 * TextToSpeech initializes asynchronously on the main thread, so the engine creates the speaker at launch;
 * until it is ready [hasVoice] answers false and `speak` calls wait in a queue. Without a
 * Vietnamese voice `speak` ends the id at once without a start (the app shows the text and the banner).
 */
class Speaker(
    private val context: Context,
    private val events: EngineEventSink,
    /** The voice language: always the home language in the app (tests pass one the phone has) */
    private val locale: Locale = Locale.forLanguageTag(HOME_LANGUAGE),
) {
    private val lock = Any()
    private var ready = false
    private var voiceAvailable = false
    private val waiting = ArrayList<Pair<String, Long>>()
    /** Ids started or queued and not yet ended */
    private val open = LinkedHashSet<Long>()
    private var usage = AudioAttributes.USAGE_ASSISTANT

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status -> onInit(status) }

    private fun onInit(status: Int) {
        val queued: List<Pair<String, Long>>
        synchronized(lock) {
            ready = status == TextToSpeech.SUCCESS
            if (ready) {
                tts.setOnUtteranceProgressListener(progress)
                voiceAvailable = checkVoice()
                if (voiceAvailable) tts.language = locale
                applyAudioAttributes()
            }
            queued = ArrayList(waiting)
            waiting.clear()
        }
        Log.i(TAG, "tts ready=$ready engine=${tts.defaultEngine} vietnamese=$voiceAvailable")
        queued.forEach { (text, id) -> speak(text, id) }
    }

    private fun checkVoice(): Boolean {
        val result = tts.isLanguageAvailable(locale)
        val voices = tts.voices.orEmpty().filter { sameLanguage(it.locale, locale) }
        // Engines name locales with ISO 639-1 or 639-2 codes (Samsung: "eng", "vie")
        val installedVoice = voices.any { TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features.orEmpty() }
        Log.i(TAG, "isLanguageAvailable($locale)=$result voices=${voices.map { it.name }} installedVoice=$installedVoice")
        return result >= TextToSpeech.LANG_AVAILABLE && installedVoice
    }

    val isReady: Boolean get() = synchronized(lock) { ready }

    /** A voice for the locale (Vietnamese in the app) is installed (re-checked on every call once TTS is ready: the user may install one) */
    fun hasVoice(): Boolean = synchronized(lock) {
        if (!ready) return false
        voiceAvailable = checkVoice()
        if (voiceAvailable) tts.language = locale
        voiceAvailable
    }

    /** Headset route: speak on the communication stream so it follows SCO; otherwise the loudspeaker */
    fun setHeadsetRoute(headset: Boolean) = synchronized(lock) {
        usage = if (headset) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_ASSISTANT
        if (ready) applyAudioAttributes()
    }

    private fun applyAudioAttributes() {
        tts.setAudioAttributes(
            AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build(),
        )
    }

    fun speak(text: String, id: Long) {
        val voice = synchronized(lock) {
            open.add(id)
            if (!ready) {
                waiting.add(text to id)
                return
            }
            voiceAvailable
        }
        // Without a Vietnamese voice the text stays on screen only. Some engines (Samsung TTS) also drop
        // the callbacks for a language they cannot load, which would leave the id open forever.
        if (!voice) {
            Log.w(TAG, "speak($id) skipped: no Vietnamese voice")
            end(id)
            return
        }
        val result = tts.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), id.toString())
        if (result != TextToSpeech.SUCCESS) {
            Log.w(TAG, "speak($id) failed: $result")
            end(id)
        }
    }

    /** Stops the current utterance and drops the queue; every open id gets its `ttsEnd` */
    fun stop() {
        val ids: List<Long>
        synchronized(lock) {
            waiting.clear()
            ids = open.toList()
        }
        if (isReady) tts.stop()
        ids.forEach { end(it) }
    }

    fun shutdown() {
        stop()
        tts.shutdown()
    }

    private fun end(id: Long) {
        val wasOpen = synchronized(lock) { open.remove(id) }
        if (wasOpen) events.ttsEnd(id)
    }

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {
            val id = utteranceId.toLongOrNull() ?: return
            if (synchronized(lock) { id in open }) events.ttsStart(id)
        }

        override fun onDone(utteranceId: String) {
            utteranceId.toLongOrNull()?.let { end(it) }
        }

        override fun onStop(utteranceId: String, interrupted: Boolean) {
            utteranceId.toLongOrNull()?.let { end(it) }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String) {
            utteranceId.toLongOrNull()?.let { end(it) }
        }

        override fun onError(utteranceId: String, errorCode: Int) {
            Log.w(TAG, "utterance $utteranceId error $errorCode")
            utteranceId.toLongOrNull()?.let { end(it) }
        }
    }

    companion object {
        private const val TAG = "Speaker"

        private fun iso3(l: Locale): String = try { l.isO3Language } catch (e: Exception) { l.language }

        fun sameLanguage(a: Locale, b: Locale) = iso3(a).equals(iso3(b), ignoreCase = true)

        /** The system TTS settings screen, where the user installs a Vietnamese voice */
        fun ttsSettingsIntent(): Intent =
            Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        fun openTtsSettings(context: Context) {
            context.startActivity(ttsSettingsIntent())
        }
    }
}
