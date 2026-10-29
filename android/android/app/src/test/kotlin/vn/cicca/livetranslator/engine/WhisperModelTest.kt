package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The Whisper context is freed when the model closes (engine shutdown, e.g. an RN reload's invalidate()) */
class WhisperModelTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Records the native calls; handles count up from 41 */
    private class FakeNative : WhisperBackend {
        val calls = CopyOnWriteArrayList<String>()
        private var next = 41L
        override val loaded = true
        override fun init(modelPath: String): Long = (next++).also { calls += "init $it" }
        override fun free(handle: Long) { calls += "free $handle" }
        override fun systemInfo() = "fake"
        override fun bindingsOk() = true
        override fun transcribe(handle: Long, samples: FloatArray, language: String, prompt: String?, threads: Int) =
            emptyArray<WhisperSegment>().also { calls += "transcribe $handle" }
    }

    private val native = FakeNative()

    private fun model(): WhisperModel {
        val bytes = ByteArray(1000) { it.toByte() }
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val store = ModelStore(tmp.root, ModelStore.Spec("m.bin", "https://example.invalid/m.bin", sha), isOnline = { false })
        store.file.writeBytes(bytes)
        return WhisperModel(store, native = native)
    }

    @Test fun closeFreesTheLoadedContextOnce() {
        val m = model()
        assertTrue(m.load())
        assertTrue(m.load())
        m.close()
        m.close()
        assertTrue(m.awaitClosed(5_000))
        assertEquals(listOf("init 41", "free 41"), native.calls.toList())
    }

    @Test fun closeWithoutALoadFreesNothing() {
        val m = model()
        m.close()
        assertTrue(m.awaitClosed(5_000))
        assertEquals(emptyList<String>(), native.calls.toList())
    }

    @Test fun aClosedModelDoesNotLoadAgain() {
        val m = model()
        m.close()
        assertFalse(m.load())
        assertEquals(emptyList<String>(), native.calls.toList())
    }

    @Test fun theContextIsFreedOnlyAfterTheQueuedTranscriptionsRan() {
        val m = model()
        assertTrue(m.load())
        val gate = CountDownLatch(1)
        val done = CountDownLatch(1)
        m.submit { gate.await(5, TimeUnit.SECONDS); native.transcribe(41, FloatArray(0), "en", null, 1) }
        m.close()
        m.submit { done.countDown() } // dropped: the worker no longer takes work
        gate.countDown()
        assertTrue(m.awaitClosed(5_000))
        assertEquals(listOf("init 41", "transcribe 41", "free 41"), native.calls.toList())
        assertEquals(1L, done.count)
    }
}
