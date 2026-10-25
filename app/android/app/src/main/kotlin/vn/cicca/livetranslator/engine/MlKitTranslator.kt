package vn.cicca.livetranslator.engine

import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeout

/**
 * Which ML Kit models a language pair needs. Pure, so the rules are unit-tested.
 *
 * ML Kit translates through English, with one model per non-English language (English is built in), so a
 * pair needs the models of both its languages. A pair with any model missing is reported as one
 * `translation` item (language = other, from = home, to = other); downloading it fetches all of them.
 *
 * [supported] maps a catalog language code to ML Kit's language tag, or null when ML Kit has no model.
 */
class TranslationModels(private val supported: (String) -> String? = { TranslateLanguage.fromLanguageTag(it) }) {
    fun mlkit(code: String): String? = supported(code)

    /** ML Kit models the pair needs, in pair order, without the built-in English */
    fun needed(home: String, other: String): List<String> =
        listOfNotNull(mlkit(home), mlkit(other)).distinct().filter { it != TranslateLanguage.ENGLISH }

    fun missing(home: String, other: String, downloaded: Set<String>): List<MissingMsg> {
        val unsupported = mlkit(home) == null || mlkit(other) == null
        val absent = needed(home, other).any { it !in downloaded }
        return if (unsupported || absent) listOf(MissingMsg(MissingKind.TRANSLATION, other, from = home, to = other))
        else emptyList()
    }

    /** Models still to download for the pair; throws `downloadFailed` when ML Kit cannot translate it */
    fun toDownload(home: String, other: String, downloaded: Set<String>): List<String> {
        if (mlkit(home) == null || mlkit(other) == null) {
            throw EngineErrors.downloadFailed("no offline translation for $home↔$other")
        }
        return needed(home, other).filter { it !in downloaded }
    }
}

/**
 * Offline translation with Google ML Kit (P4). Never downloads from [translate]: models only arrive
 * through [download] (R17, no network in the translator path).
 */
class MlKitTranslator(
    private val isOnline: () -> Boolean,
    private val models: TranslationModels = TranslationModels(),
    private val downloadTimeoutMs: Long = 15 * 60_000L,
) {
    private val manager = RemoteModelManager.getInstance()
    private val translators = HashMap<Pair<String, String>, Translator>()

    /** Every language ML Kit can translate, as language tags */
    fun translatable(): List<String> = TranslateLanguage.getAllLanguages().sorted()

    suspend fun downloaded(): Set<String> =
        manager.getDownloadedModels(TranslateRemoteModel::class.java).await().map { it.language }.toSet() +
            TranslateLanguage.ENGLISH

    /** For the synchronous `missing()` call: ML Kit completes on its own executor, so blocking here is safe */
    fun downloadedBlocking(): Set<String> = runBlocking { withTimeout(5_000) { downloaded() } }

    fun missing(home: String, other: String): List<MissingMsg> =
        models.missing(home, other, downloadedBlocking())

    /** Downloads every model the pair still needs. [progress] gets 0 before and 1 after (no finer progress in ML Kit) */
    suspend fun download(home: String, other: String, progress: (Double) -> Unit) {
        val todo = models.toDownload(home, other, downloaded())
        progress(0.0)
        // ML Kit waits for a network indefinitely: fail now so the user gets Retry
        if (todo.isNotEmpty() && !isOnline()) throw EngineErrors.downloadFailed("no network")
        for (language in todo) {
            val model = TranslateRemoteModel.Builder(language).build()
            try {
                withTimeout(downloadTimeoutMs) {
                    manager.download(model, DownloadConditions.Builder().build()).await()
                }
            } catch (e: Exception) {
                throw EngineErrors.downloadFailed("translation model $language: ${e.message}")
            }
            Log.i(TAG, "downloaded translation model $language")
        }
        progress(1.0)
    }

    suspend fun translate(text: String, from: String, to: String): String {
        val source = models.mlkit(from) ?: throw EngineErrors.translateFailed("unsupported language $from")
        val target = models.mlkit(to) ?: throw EngineErrors.translateFailed("unsupported language $to")
        if (text.isBlank() || source == target) return text
        val have = downloaded()
        val absent = listOf(source, target).filter { it !in have }
        if (absent.isNotEmpty()) throw EngineErrors.notReady("translation model missing: $absent")
        val translator = synchronized(translators) {
            translators.getOrPut(source to target) {
                Translation.getClient(
                    TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(target).build(),
                )
            }
        }
        return try {
            translator.translate(text).await()
        } catch (e: Exception) {
            throw EngineErrors.translateFailed(e.message)
        }
    }

    fun close() {
        synchronized(translators) {
            translators.values.forEach { it.close() }
            translators.clear()
        }
    }

    private companion object {
        const val TAG = "MlKitTranslator"
    }
}
