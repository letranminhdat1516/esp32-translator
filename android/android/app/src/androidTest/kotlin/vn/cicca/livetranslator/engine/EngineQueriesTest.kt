package vn.cicca.livetranslator.engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * P2.0a: `capabilities(home)` and `missing(pair)` are async host calls. Pigeon launches them on the main
 * thread; the engine does the slow queries on a background thread, so the main thread stays free, and uses the
 * home language it is given.
 */
@RunWith(AndroidJUnit4::class)
class EngineQueriesTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    /** A catalog whose queries are held until released, recording the home and the thread they ran on */
    private class SlowCatalog : RecognizerCatalog {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        @Volatile var home: String? = null
        @Volatile var onMain: Boolean? = null

        private fun hold(home: String) {
            this.home = home
            onMain = Looper.myLooper() == Looper.getMainLooper()
            entered.countDown()
            release.await(10, TimeUnit.SECONDS)
        }

        override fun kinds(home: String, languages: List<String>): Map<String, List<String>> {
            hold(home)
            return mapOf(home to listOf(Kinds.WHISPER))
        }

        override fun speechModelsMissing(pair: PairMsg): List<String> {
            hold(pair.home)
            return listOf(pair.other)
        }

        override fun create(request: RecognizerRequest): UtteranceRecognizer = throw AssertionError("not used")
        override fun mineKind(home: String, recognizerX: String) = Kinds.WHISPER
    }

    private val catalog = SlowCatalog()
    private lateinit var engine: NativeVoiceEngine

    private fun newEngine() {
        instrumentation.runOnMainSync { engine = NativeVoiceEngine(context, object : EngineEventSink {}, catalog) }
    }

    @After fun tearDown() {
        if (::engine.isInitialized) instrumentation.runOnMainSync { engine.shutdown() }
    }

    /** Launches [call] on the main thread as the pigeon handler does; await() returns its result */
    private fun <T> launchOnMain(call: suspend () -> T): (Long) -> T? {
        var result: T? = null
        val done = CountDownLatch(1)
        instrumentation.runOnMainSync {
            CoroutineScope(Dispatchers.Main).launch {
                result = call()
                done.countDown()
            }
        }
        return { ms -> if (done.await(ms, TimeUnit.MILLISECONDS)) result else null }
    }

    /** True when the main thread runs a posted task within [ms] */
    private fun mainThreadFree(ms: Long): Boolean {
        val ran = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post { ran.countDown() }
        return ran.await(ms, TimeUnit.MILLISECONDS)
    }

    @Test fun aSlowCapabilitiesLeavesTheMainThreadFreeAndUsesTheGivenHome() {
        newEngine()
        val result = launchOnMain { engine.capabilities("ja") }
        assertTrue("the query started", catalog.entered.await(5, TimeUnit.SECONDS))
        assertTrue("the main thread runs other work while capabilities is held", mainThreadFree(2_000))
        assertEquals(false, catalog.onMain)
        assertEquals("ja", catalog.home)
        assertEquals("not answered while held", null, result(100))
        catalog.release.countDown()
        val caps = result(10_000)
        assertNotNull("answered once released", caps)
        assertEquals(listOf(RecognizerEntryMsg("ja", listOf(Kinds.WHISPER))), caps!!.recognizers)
    }

    @Test fun aSlowMissingLeavesTheMainThreadFreeAndNamesThePairsHome() {
        newEngine()
        val result = launchOnMain { engine.missing(PairMsg("ja", "en", 1)) }
        assertTrue("the query started", catalog.entered.await(5, TimeUnit.SECONDS))
        assertTrue("the main thread runs other work while missing is held", mainThreadFree(2_000))
        assertEquals(false, catalog.onMain)
        catalog.release.countDown()
        val missing = result(10_000)
        assertNotNull("answered once released", missing)
        assertTrue(missing.toString(), MissingMsg(MissingKind.SPEECH_MODEL, "en") in missing!!)
        // A missing voice, if any, is the pair's home voice
        assertFalse(missing.toString(), missing.any { it.kind == MissingKind.TTS_VOICE && it.language != "ja" })
    }
}
