package vn.cicca.livetranslator.engine

import java.text.Normalizer
import java.util.Locale

/**
 * One Whisper segment: its text, the model's probability that it was not speech at all, and the mean
 * probability of its text tokens (how sure the decoder was of the words)
 */
data class WhisperSegment(val text: String, val noSpeechProb: Float, val tokenProb: Float = 1f)

/**
 * Drops Whisper's hallucinations (Review Focus 5). On silence, music or noise Whisper tends to produce
 * phrases from its training subtitles, or to loop one phrase. Rules:
 * - a segment with `no_speech_prob > 0.6` is dropped;
 * - a sentence containing a blocklisted phrase is dropped, and bracketed noise tags ("[Music]",
 *   "(applause)", "♪") are removed; a result that is only "you" is dropped;
 * - the whole result is dropped when one phrase repeats more than twice: the same sentence three times or
 *   more, or a run of two or more words repeated three times in a row (single words may repeat:
 *   "vâng vâng vâng" is ordinary Vietnamese).
 *
 * Returns the cleaned text, or null when nothing real is left.
 */
object HallucinationFilter {
    const val NO_SPEECH_THRESHOLD = 0.6f

    /** Normalized (see [normalize]) phrases; a sentence containing one is dropped */
    private val blocklist = listOf(
        "thank you for watching",
        "thanks for watching",
        "subtitles by",
        "cảm ơn các bạn đã theo dõi",
        "hãy subscribe",
    ).map { normalize(it) }

    /** Whole results that are hallucinations on their own (Whisper says "you" on digital silence) */
    private val aloneBlocklist = setOf("you")

    private val noiseTags = Regex("""\[[^\]]*]|\([^)]*\)|\*[^*]*\*|[♪♫]""")
    private val sentenceEnd = Regex("""(?<=[.!?。！？…])\s+""")

    fun filter(segments: List<WhisperSegment>): String? {
        val speech = segments.filter { it.noSpeechProb <= NO_SPEECH_THRESHOLD }
            .joinToString(" ") { it.text.trim() }
        val untagged = Normalizer.normalize(noiseTags.replace(speech, " "), Normalizer.Form.NFC)
            .replace(Regex("""\s+"""), " ").trim()
        val sentences = untagged.split(sentenceEnd).map { it.trim() }
            .filter { s -> normalize(s).isNotEmpty() }
            .filter { s -> blocklist.none { it in normalize(s) } }
        if (sentences.isEmpty()) return null
        if (normalize(sentences.joinToString(" ")) in aloneBlocklist) return null
        if (repeats(sentences)) return null
        return sentences.joinToString(" ")
    }

    private fun repeats(sentences: List<String>): Boolean {
        if (sentences.groupingBy { normalize(it) }.eachCount().values.any { it > 2 }) return true
        val words = normalize(sentences.joinToString(" ")).split(' ')
        for (n in 2..words.size / 3) {
            for (i in 0..words.size - 3 * n) {
                val a = words.subList(i, i + n)
                if (a == words.subList(i + n, i + 2 * n) && a == words.subList(i + 2 * n, i + 3 * n)) return true
            }
        }
        return false
    }

    /** Lower case, letters and digits only, single spaces */
    private fun normalize(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFC).lowercase(Locale.ROOT)
            .map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("")
            .split(' ').filter { it.isNotEmpty() }.joinToString(" ")
}
