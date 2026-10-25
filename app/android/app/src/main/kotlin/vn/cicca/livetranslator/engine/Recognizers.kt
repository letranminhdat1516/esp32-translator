package vn.cicca.livetranslator.engine

/** `RecognizerKind` names as the Dart side knows them (model.dart) */
object Kinds {
    const val OS_ON_DEVICE = "osOnDevice"
    const val WHISPER = "whisper"
    const val OS_ONLINE = "osOnline"
}

/** A recognition result. [startMs]/[endMs] are ms since the session start (mine) */
data class Recognized(
    val text: String,
    val final: Boolean,
    val confidence: Double? = null,
    val startMs: Long = 0,
    val endMs: Long = 0,
)

/**
 * A recognizer that takes audio from the engine: the mic after the gate (mine) or the board's audio
 * (theirs), one utterance at a time.
 */
interface UtteranceRecognizer {
    fun audio(pcm: ShortArray, sampleRate: Int)
    /** The utterance ended (gate closed or board silence): produce its final result */
    fun endUtterance(startMs: Long, endMs: Long)
    fun setHints(hints: List<String>) {}
    fun close()

    /**
     * True for an OS recognizer below API 33 on the mic side: it listens to the mic itself (it cannot take
     * fed audio), so the engine does not open the mic and `micOn` calls [listen] instead.
     */
    val ownsMic: Boolean get() = false
    fun listen(on: Boolean) {}
}

/** What a recognizer needs from the session */
class RecognizerRequest(
    val kind: String,
    val language: String,
    val hints: List<String>,
    /** The mic side (home language) or the board side */
    val mine: Boolean,
    /** ms since the session started */
    val clock: () -> Long,
    val onResult: (Recognized) -> Unit,
    /** Speech started / stopped, for a recognizer that owns the mic (drives the `gate` event) */
    val onSpeech: (Boolean) -> Unit = {},
)

/**
 * What recognizers this phone has, and building them for a session.
 */
interface RecognizerCatalog {
    /** Recognizer kinds per language code, in preference order (P3) */
    fun kinds(languages: List<String>): Map<String, List<String>>

    /** Languages of the pair whose only offline recognizer is Whisper and whose model is not downloaded */
    fun speechModelsMissing(pair: PairMsg): List<String>

    /**
     * The recognizer for the request; throws `notReady` when it cannot run (missing model, or an OS
     * recognizer asked to take fed audio before Android 13).
     */
    fun create(request: RecognizerRequest): UtteranceRecognizer

    /** The kind used for the Vietnamese side when Dart names only the other side's kind */
    fun mineKind(recognizerX: String): String
}

/**
 * Which recognizer kinds this phone offers per language (P3, ARCHITECTURE §5). Pure, unit-tested.
 *
 * Order: on-device OS recognizer, Whisper, online OS recognizer. The other language arrives from the board
 * as PCM (`feedTheirAudio`), and Android's recognizers accept a PCM feed only from API 33
 * (EXTRA_AUDIO_SOURCE); below that they are mic-only, so they are offered only for the home language,
 * which comes from the mic. On the Note 9 (API 29) the board side therefore has Whisper only.
 */
class RecognizerChoice(
    private val api: Int,
    /** Languages the on-device OS recognizer supports (empty below API 31 or when unavailable) */
    private val onDeviceLanguages: Set<String>,
    /** An online recognition service is installed */
    private val onlineAvailable: Boolean,
    /** whisper.cpp is built for this ABI (the model may still need a download) */
    private val whisperAvailable: Boolean,
) {
    fun canFeed(kind: String) = kind == Kinds.WHISPER || api >= FED_AUDIO_API

    fun kinds(language: String): List<String> {
        val fromMic = language == HOME_LANGUAGE
        fun osUsable(kind: String) = fromMic || canFeed(kind)
        return buildList {
            if (language in onDeviceLanguages && osUsable(Kinds.OS_ON_DEVICE)) add(Kinds.OS_ON_DEVICE)
            if (whisperAvailable && language in WHISPER_LANGUAGES) add(Kinds.WHISPER)
            if (onlineAvailable && osUsable(Kinds.OS_ONLINE)) add(Kinds.OS_ONLINE)
        }
    }

    /**
     * The home side's kind. The pigeon API names only the other side's kind ([recognizerX]); the home side
     * takes the best offline one, and online only when Dart asked for online (its consent) and nothing
     * offline exists.
     */
    fun mine(recognizerX: String): String = when {
        HOME_LANGUAGE in onDeviceLanguages -> Kinds.OS_ON_DEVICE
        whisperAvailable -> Kinds.WHISPER
        recognizerX == Kinds.OS_ONLINE && onlineAvailable -> Kinds.OS_ONLINE
        else -> Kinds.WHISPER
    }

    companion object {
        /** Android 13: SpeechRecognizer takes audio from a file descriptor (EXTRA_AUDIO_SOURCE) */
        const val FED_AUDIO_API = 33

        /** Languages of the multilingual Whisper models (whisper.cpp g_lang) */
        val WHISPER_LANGUAGES = setOf(
            "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id",
            "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg",
            "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br",
            "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so",
            "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt",
            "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
        )
    }
}
