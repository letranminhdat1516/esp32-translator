package vn.cicca.livetranslator.engine

import android.speech.SpeechRecognizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Contract ruling: `feedTheirAudio` rejects with notReady whenever the their-side recognizer is not running
 * (never started, stopped, or given up after a fatal error) until the next successful start.
 */
class TheirFeedTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Recording : UtteranceRecognizer {
        var samples = 0
        override fun audio(pcm: ShortArray, sampleRate: Int) { samples += pcm.size }
        override fun endUtterance(startMs: Long, endMs: Long) {}
        override fun close() {}
    }

    private val packet = ShortArray(320)

    /** A steady voiced sound: 140 Hz and its first harmonics, about -30 dB */
    private fun vowel(seconds: Double): FloatArray = FloatArray((seconds * 16_000).toInt()) { i ->
        val t = i / 16_000.0
        (1..5).sumOf { h -> kotlin.math.sin(2 * Math.PI * 140.0 * h * t) / h }.toFloat() * 0.02f
    }

    private fun assertNotReady(feed: TheirFeed) {
        try {
            feed.feed(packet, 16_000)
            fail("expected notReady")
        } catch (e: EngineException) {
            assertEquals("notReady", e.code)
        }
    }

    @Test fun beforeAnyStartFeedingIsNotReady() {
        assertNotReady(TheirFeed())
    }

    @Test fun aRunningRecognizerTakesTheAudio() {
        val feed = TheirFeed()
        val r = Recording()
        feed.attach(r, feed.newLife())
        feed.feed(packet, 16_000)
        assertEquals(320, r.samples)
    }

    @Test fun afterAFatalErrorFeedingIsNotReadyUntilTheNextStart() {
        val feed = TheirFeed()
        val first = Recording()
        val life = feed.newLife()
        feed.attach(first, life)
        life.die("Whisper could not load")
        assertNotReady(feed)
        assertNotReady(feed) // keeps rejecting
        assertEquals(0, first.samples)
        // A new start: new recognizer, new life
        val second = Recording()
        feed.attach(second, feed.newLife())
        feed.feed(packet, 16_000)
        assertEquals(320, second.samples)
        // A late fatal from the old recognizer does not touch the new one
        life.die("late")
        feed.feed(packet, 16_000)
        assertEquals(640, second.samples)
    }

    @Test fun afterStopFeedingIsNotReady() {
        val feed = TheirFeed()
        feed.attach(Recording(), feed.newLife())
        feed.detach()
        assertNotReady(feed)
    }

    @Test fun osRecognizerErrorsThatEndTheRecognizerAreFatalRoutineOnesAreNot() {
        assertTrue(OsRecognizer.isFatal(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS))
        assertTrue(OsRecognizer.isFatal(SpeechRecognizer.ERROR_SERVER_DISCONNECTED))
        assertTrue(OsRecognizer.isFatal(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED))
        assertTrue(OsRecognizer.isFatal(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE))
        assertFalse(OsRecognizer.isFatal(SpeechRecognizer.ERROR_NO_MATCH))
        assertFalse(OsRecognizer.isFatal(SpeechRecognizer.ERROR_SPEECH_TIMEOUT))
        assertFalse(OsRecognizer.isFatal(SpeechRecognizer.ERROR_NETWORK))
        assertFalse(OsRecognizer.isFatal(SpeechRecognizer.ERROR_RECOGNIZER_BUSY))
    }

    /** Whisper whose model cannot load (JNI bindings missing) gives up on the first utterance */
    @Test fun whisperReportsFatalWhenTheModelCannotLoad() {
        val native = object : WhisperBackend {
            override val loaded = true
            override fun init(modelPath: String) = 1L
            override fun free(handle: Long) {}
            override fun systemInfo() = "fake"
            override fun bindingsOk() = false
            override fun transcribe(handle: Long, samples: FloatArray, language: String, prompt: String?, threads: Int) =
                emptyArray<WhisperSegment>()
        }
        val bytes = ByteArray(100) { it.toByte() }
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val store = ModelStore(tmp.root, ModelStore.Spec("m.bin", "https://example.invalid/m.bin", sha), isOnline = { false })
        store.file.writeBytes(bytes)
        val model = WhisperModel(store, native = native)
        val fatal = CountDownLatch(1)
        var reason: String? = null
        val request = RecognizerRequest(
            Kinds.WHISPER, "en", emptyList(), mine = false, clock = { 0L }, onResult = {},
            onFatal = { reason = it; fatal.countDown() },
        )
        val r = WhisperRecognizer(model, request)
        r.audio(VoiceGate.toPcm16(vowel(1.0)), 16_000)
        r.endUtterance(0, 1000)
        assertTrue("onFatal called", fatal.await(5, TimeUnit.SECONDS))
        assertTrue(reason.orEmpty(), reason.orEmpty().contains("Whisper"))
        r.close()
        model.close()
    }
}
