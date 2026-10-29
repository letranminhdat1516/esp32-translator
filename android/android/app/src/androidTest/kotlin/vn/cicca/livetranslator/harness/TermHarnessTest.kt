package vn.cicca.livetranslator.harness

import android.content.Context
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import vn.cicca.livetranslator.engine.HOME_LANGUAGE
import vn.cicca.livetranslator.engine.MlKitTranslator
import vn.cicca.livetranslator.engine.isOnline
import java.io.File

/**
 * Term harness (P2.5, R10), ML Kit half. Skipped unless run with `-e harness true`.
 *
 * Masking, restoring and scoring stay in the app's TypeScript core (android/scripts/term-harness.mjs);
 * this test only translates what that script asks for, with the engine's own [MlKitTranslator]:
 *
 *   in:  <external files>/term-harness/requests.tsv   from<TAB>to<TAB>text            (text escaped: \\ \t \n \r)
 *   out: <external files>/term-harness/responses.tsv  from<TAB>to<TAB>text<TAB>translation  ("!message" on error)
 *        <external files>/term-harness/summary.md     requests, errors and time per pair (also in logcat, tag TermHarness)
 *
 * <external files> is /sdcard/Android/data/vn.cicca.livetranslator/files. By hand (android/tool/term_harness.sh does it all):
 *
 *   node scripts/term-harness.mjs --translator record:/tmp/requests.tsv
 *   adb shell mkdir -p /sdcard/Android/data/vn.cicca.livetranslator/files/term-harness
 *   adb push /tmp/requests.tsv /sdcard/Android/data/vn.cicca.livetranslator/files/term-harness/requests.tsv
 *   adb shell am instrument -w -e harness true -e class vn.cicca.livetranslator.harness.TermHarnessTest \
 *       vn.cicca.livetranslator.test/androidx.test.runner.AndroidJUnitRunner
 *   adb pull /sdcard/Android/data/vn.cicca.livetranslator/files/term-harness/responses.tsv /tmp/responses.tsv
 *   node scripts/term-harness.mjs --translator replay:/tmp/responses.tsv
 *
 * Models missing on the phone are downloaded first (needs the network once).
 */
@RunWith(AndroidJUnit4::class)
class TermHarnessTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun translateRequests() = runBlocking {
        assumeTrue("run with -e harness true", InstrumentationRegistry.getArguments().getString("harness") == "true")
        val dir = File(context.getExternalFilesDir(null), "term-harness")
        val requests = File(dir, "requests.tsv")
        assertTrue("push the requests first: $requests", requests.isFile)

        val rows = requests.readLines().filter { it.isNotBlank() }.map { line ->
            val cols = line.split('\t')
            require(cols.size == 3) { "bad request line: $line" }
            Request(cols[0], cols[1], cols[2])
        }
        val translator = MlKitTranslator({ context.isOnline() })
        try {
            // Every pair is the home language and one other; fetch what is missing before timing anything
            for (other in rows.flatMap { listOf(it.from, it.to) }.toSet() - HOME_LANGUAGE) {
                if (translator.missing(HOME_LANGUAGE, other).isNotEmpty()) {
                    Log.i(TAG, "downloading the models for $HOME_LANGUAGE↔$other")
                    translator.download(HOME_LANGUAGE, other) {}
                }
            }

            val stats = LinkedHashMap<String, Stat>()
            val out = StringBuilder()
            rows.forEachIndexed { i, r ->
                val stat = stats.getOrPut("${r.from}>${r.to}") { Stat() }
                val t0 = System.nanoTime()
                val answer = try {
                    escapeField(translator.translate(unescapeField(r.text), r.from, r.to))
                } catch (e: Exception) {
                    stat.errors++
                    "!" + escapeField(e.message ?: e.javaClass.simpleName)
                }
                stat.requests++
                stat.ms += (System.nanoTime() - t0) / 1_000_000
                out.append(r.from).append('\t').append(r.to).append('\t').append(r.text).append('\t').append(answer).append('\n')
                if ((i + 1) % 200 == 0) Log.i(TAG, "${i + 1}/${rows.size} translated")
            }
            File(dir, "responses.tsv.part").apply { writeText(out.toString()) }.renameTo(File(dir, "responses.tsv"))

            val summary = buildString {
                append("| Pair | Requests | Errors | ms per request |\n|---|---:|---:|---:|\n")
                for ((pair, s) in stats) append("| $pair | ${s.requests} | ${s.errors} | ${s.ms / maxOf(1, s.requests)} |\n")
            }
            File(dir, "summary.md").writeText(summary)
            summary.lines().forEach { Log.i(TAG, it) }
            Log.i(TAG, "wrote ${File(dir, "responses.tsv")}; score it with scripts/term-harness.mjs --translator replay:<file>")
        } finally {
            translator.close()
        }
    }

    private data class Request(val from: String, val to: String, val text: String)

    private class Stat(var requests: Int = 0, var errors: Int = 0, var ms: Long = 0)

    private companion object {
        const val TAG = "TermHarness"

        /** Same escaping as escapeField in android/src/harness/termHarness.ts. */
        fun escapeField(s: String): String = buildString {
            for (c in s) when (c) {
                '\\' -> append("\\\\")
                '\t' -> append("\\t")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                else -> append(c)
            }
        }

        fun unescapeField(s: String): String = buildString {
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '\\' && i + 1 < s.length && s[i + 1] in "\\tnr") {
                    append(
                        when (s[i + 1]) {
                            't' -> '\t'
                            'n' -> '\n'
                            'r' -> '\r'
                            else -> '\\'
                        },
                    )
                    i += 2
                } else {
                    append(c)
                    i++
                }
            }
        }
    }
}
