package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Fix round 1, finding 4: a mic that cannot start or stops delivering is reported, not swallowed */
class MicCaptureTest {
    private val sessions = CopyOnWriteArrayList<AudioSessionMsg>()
    private val events = object : EngineEventSink {
        override fun audioSession(msg: AudioSessionMsg) { sessions += msg }
    }
    private val sink = object : UtteranceSink {
        override fun audio(pcm: ShortArray) {}
        override fun ended(startMs: Long, endMs: Long) {}
    }

    /** Delivers [chunks] reads of silence, then fails with [failWith] (or keeps delivering when null) */
    private class FakeMic(private val chunks: Int = Int.MAX_VALUE, private val failWith: Int? = null) : MicSource {
        @Volatile var reads = 0
        @Volatile var stopped = false
        override val deviceName = "fake"
        override fun read(buffer: ShortArray): Int {
            if (reads >= chunks) {
                failWith?.let { return it }
                Thread.sleep(5)
                return 0
            }
            reads++
            Thread.sleep(1)
            return buffer.size
        }
        override fun silenced() = false
        override fun stop() { stopped = true }
    }

    private fun capture(open: () -> MicSource) = MicCapture(VoiceGate(), events, sink, clock = { 0L }, open = open)

    @Test fun aMicThatCannotOpenThrowsNotReadyAndReportsAnInterruption() {
        val mic = capture { throw IllegalStateException("AudioRecord not initialized") }
        try {
            mic.start()
            throw AssertionError("expected notReady")
        } catch (e: EngineException) {
            assertEquals("notReady", e.code)
        }
        assertFalse(mic.isRunning)
        assertEquals(listOf(AudioSessionMsg(AudioSessionKind.INTERRUPTED, null)), sessions.toList())
    }

    @Test fun aReadErrorStopsTheMicAndReportsAnInterruption() {
        val fake = FakeMic(chunks = 10, failWith = -3)
        val mic = capture { fake }
        mic.start()
        val end = System.currentTimeMillis() + 2_000
        while (mic.isRunning && System.currentTimeMillis() < end) Thread.sleep(10)
        assertFalse("stopped after the read error", mic.isRunning)
        assertTrue(fake.stopped)
        assertTrue(mic.lastError.orEmpty(), mic.lastError.orEmpty().contains("-3"))
        assertEquals(listOf(AudioSessionMsg(AudioSessionKind.INTERRUPTED, null)), sessions.toList())
    }

    @Test fun aWorkingMicReadsUntilStopped() {
        val fake = FakeMic()
        val mic = capture { fake }
        mic.start()
        Thread.sleep(100)
        mic.stop()
        assertTrue(fake.reads > 0)
        assertTrue(fake.stopped)
        assertTrue("no interruption for a normal stop", sessions.isEmpty())
    }
}
