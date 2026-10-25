package vn.cicca.livetranslator.engine

import android.content.Context

/** The recognizers of this phone (P3). Filled by the OS recognizer (E5) and Whisper (E6) tasks. */
class DeviceRecognizers(@Suppress("unused") private val context: Context) : RecognizerCatalog {
    override fun kinds(languages: List<String>): Map<String, List<String>> = emptyMap()

    override fun speechModelsMissing(pair: PairMsg): List<String> = emptyList()

    override fun create(
        kind: String, language: String, hints: List<String>, onResult: (Recognized) -> Unit,
    ): UtteranceRecognizer = throw EngineErrors.notReady("no $kind recognizer for $language")

    override fun mineKind(recognizerX: String): String = Kinds.WHISPER
}
