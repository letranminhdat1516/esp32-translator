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
}

/**
 * What recognizers this phone has, and building them for a session.
 */
interface RecognizerCatalog {
    /** Recognizer kinds per language code, in preference order (P3) */
    fun kinds(languages: List<String>): Map<String, List<String>>

    /** Languages of the pair whose only offline recognizer is Whisper and whose model is not downloaded */
    fun speechModelsMissing(pair: PairMsg): List<String>

    /**
     * The recognizer for [language] of [kind] fed by the engine; throws `notReady` when it cannot run
     * (missing model, or an OS recognizer that cannot take fed audio before Android 13).
     */
    fun create(kind: String, language: String, hints: List<String>, onResult: (Recognized) -> Unit): UtteranceRecognizer

    /** The kind used for the Vietnamese side when Dart names only the other side's kind */
    fun mineKind(recognizerX: String): String
}
