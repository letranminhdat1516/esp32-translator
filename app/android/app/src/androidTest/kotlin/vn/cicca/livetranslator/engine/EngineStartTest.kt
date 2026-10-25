package vn.cicca.livetranslator.engine

import android.Manifest
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Fix round 1, finding 2: start() is serialized against stop() and later starts, and recovers from failures */
@RunWith(AndroidJUnit4::class)
class EngineStartTest {
    @get:Rule val mic: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    private class Rec(val language: String) : UtteranceRecognizer {
        @Volatile var closed = false
        override fun audio(pcm: ShortArray, sampleRate: Int) {}
        override fun endUtterance(startMs: Long, endMs: Long) {}
        override fun close() { closed = true }
    }

    /** Recognizers whose creation can be held, to put stop() or a second start() in the middle of a start */
    private class Catalog : RecognizerCatalog {
        val created = CopyOnWriteArrayList<Rec>()
        @Volatile var holdNext = false
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)

        override fun kinds(languages: List<String>) = emptyMap<String, List<String>>()
        override fun speechModelsMissing(pair: PairMsg) = emptyList<String>()
        override fun mineKind(recognizerX: String) = Kinds.WHISPER
        override fun create(request: RecognizerRequest): UtteranceRecognizer {
            if (holdNext) {
                holdNext = false
                entered.countDown()
                release.await(10, TimeUnit.SECONDS)
            }
            return Rec(request.language).also { created += it }
        }
    }

    private class Foreground : ConversationForeground {
        @Volatile var starts = 0
        @Volatile var stops = 0
        @Volatile var failNext = false
        @Volatile var up = false
        override fun start() {
            starts++
            if (failNext) {
                failNext = false
                throw IllegalStateException("ForegroundServiceStartNotAllowedException")
            }
            up = true
        }
        override fun stop() { stops++; up = false }
    }

    private val catalog = Catalog()
    private val foreground = Foreground()
    private lateinit var engine: NativeVoiceEngine

    private fun newEngine() {
        instrumentation.runOnMainSync { engine = NativeVoiceEngine(context, object : EngineEventSink {}, catalog, foreground) }
    }

    @After fun tearDown() {
        if (::engine.isInitialized) instrumentation.runOnMainSync { engine.shutdown() }
    }

    private fun pair(generation: Long) = PairMsg(HOME_LANGUAGE, "en", generation)

    /** Runs start() on its own thread; join() returns its failure, if any */
    private fun startAsync(generation: Long): () -> Throwable? {
        var failure: Throwable? = null
        val t = thread {
            try { runBlocking { engine.start(pair(generation), Kinds.WHISPER, emptyList()) } } catch (e: Throwable) { failure = e }
        }
        return { t.join(10_000); failure }
    }

    @Test fun stopDuringStartLeavesNothingRunning() {
        newEngine()
        catalog.holdNext = true
        val join = startAsync(1)
        assertTrue(catalog.entered.await(5, TimeUnit.SECONDS))
        engine.stop()
        catalog.release.countDown()
        assertEquals(null, join())
        assertFalse("no session after stop", engine.isRunning)
        assertTrue("what the stale start built is closed", catalog.created.all { it.closed })
        assertFalse("the service was not brought up", foreground.up)
    }

    @Test fun aSecondStartSupersedesTheFirst() {
        newEngine()
        catalog.holdNext = true
        val first = startAsync(1)
        assertTrue(catalog.entered.await(5, TimeUnit.SECONDS))
        // While the first is still building its recognizers, the pair changes
        val second = startAsync(2)
        assertEquals(null, second())
        // The first start is still held inside its first create: everything so far is the second's
        val new = catalog.created.toList()
        catalog.release.countDown()
        assertEquals(null, first())
        assertTrue(engine.isRunning)
        assertEquals(2L, engine.runningGeneration)
        val old = catalog.created.filter { it !in new }
        assertEquals("the first start built both its recognizers", 2, old.size)
        assertTrue("the first start's recognizers are closed", old.all { it.closed })
        assertTrue("the second's are open", new.size == 2 && new.none { it.closed })
        assertEquals("the service started once", 1, foreground.starts)
    }

    @Test fun aFailedServiceStartLetsTheNextStartRetry() = runBlocking {
        newEngine()
        foreground.failNext = true
        try {
            engine.start(pair(1), Kinds.WHISPER, emptyList())
            throw AssertionError("expected notReady")
        } catch (e: FlutterError) {
            assertEquals("notReady", e.code)
        }
        assertFalse(engine.isRunning)
        assertTrue("recognizers of the failed start are closed", catalog.created.all { it.closed })
        // Same pair again: not a no-op, it really starts this time
        engine.start(pair(1), Kinds.WHISPER, emptyList())
        assertTrue(engine.isRunning)
        assertTrue(foreground.up)
        assertEquals(2, foreground.starts)
    }

    @Test fun switchingPairsKeepsTheServiceUp() = runBlocking {
        newEngine()
        engine.start(pair(1), Kinds.WHISPER, emptyList())
        val first = catalog.created.toList()
        engine.start(pair(2), Kinds.WHISPER, emptyList())
        assertEquals(1, foreground.starts)
        assertEquals(0, foreground.stops)
        assertTrue("the first session is closed", first.size == 2 && first.all { it.closed })
        assertTrue("the second is open", catalog.created.filter { it !in first }.none { it.closed })
        engine.stop()
        assertEquals(1, foreground.stops)
        assertTrue(catalog.created.all { it.closed })
    }
}
