package vn.cicca.livetranslator.engine

import android.Manifest
import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/**
 * E1 on the Note 9: a conversation started through the engine runs the foreground service and the mic,
 * reports the route, and keeps running with the screen off (60 s, a heartbeat every 10 s).
 */
@RunWith(AndroidJUnit4::class)
class VoiceServiceTest {
    @get:Rule val mic: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val sessions = CopyOnWriteArrayList<AudioSessionMsg>()
    private val gates = CopyOnWriteArrayList<Boolean>()
    private val sink = object : EngineEventSink {
        override fun audioSession(msg: AudioSessionMsg) { sessions += msg }
        override fun gate(open: Boolean) { gates += open }
    }

    /** Records what the engine feeds; stands in for Whisper / the OS recognizers */
    private class Recording : UtteranceRecognizer {
        @Volatile var samples = 0L
        @Volatile var utterances = 0
        override fun audio(pcm: ShortArray, sampleRate: Int) { samples += pcm.size }
        override fun endUtterance(startMs: Long, endMs: Long) { utterances++ }
        override fun close() {}
    }

    private val created = CopyOnWriteArrayList<Pair<String, String>>()
    private val catalog = object : RecognizerCatalog {
        override fun kinds(languages: List<String>) = emptyMap<String, List<String>>()
        override fun speechModelsMissing(pair: PairMsg) = emptyList<String>()
        override fun create(request: RecognizerRequest): UtteranceRecognizer {
            created += request.kind to request.language
            return Recording()
        }
        override fun mineKind(recognizerX: String) = Kinds.WHISPER
    }
    private lateinit var engine: NativeVoiceEngine

    private fun newEngine() {
        instrumentation.runOnMainSync { engine = NativeVoiceEngine(context, sink, catalog) }
    }

    @After fun tearDown() {
        if (::engine.isInitialized) instrumentation.runOnMainSync { engine.shutdown() }
        wake()
    }

    @Test fun startRunsTheServiceAndReportsTheRoute() = runBlocking {
        newEngine()
        engine.start(PairMsg(HOME_LANGUAGE, "en", 1), Kinds.WHISPER, emptyList())
        waitFor(5_000) { VoiceService.running }
        assertTrue("foreground service running", VoiceService.running)
        assertEquals(listOf(Kinds.WHISPER to HOME_LANGUAGE, Kinds.WHISPER to "en"), created.toList())
        // No headset on the test phone: the phone mic, reported once
        assertEquals(AudioSessionMsg(AudioSessionKind.ROUTE_CHANGED, AudioRoute.PHONE_MIC), sessions.first())
        // Idempotent start, then stop
        engine.start(PairMsg(HOME_LANGUAGE, "en", 1), Kinds.WHISPER, emptyList())
        assertEquals(2, created.size)
        engine.stop()
        engine.stop()
        waitFor(5_000) { !VoiceService.running }
        assertTrue("service stopped", !VoiceService.running)
    }

    @Test fun keepsListeningWithTheScreenOffFor60Seconds() = runBlocking {
        newEngine()
        wake()
        engine.start(PairMsg(HOME_LANGUAGE, "en", 2), Kinds.WHISPER, emptyList())
        engine.micOn(true)
        waitFor(5_000) { VoiceService.running }
        SystemClock.sleep(2_000)

        val power = context.getSystemService(PowerManager::class.java)
        shell("input keyevent 26") // power button: screen off
        waitFor(5_000) { !power.isInteractive }
        assertTrue("screen is off", !power.isInteractive)
        val before = framesRead()
        val beatsBefore = VoiceService.heartbeats
        SystemClock.sleep(60_000)
        val after = framesRead()
        val beats = VoiceService.heartbeats - beatsBefore
        val status = VoiceService.status()
        // Android did not silence the capture. (Exact zeros between sounds are normal here: Samsung's noise
        // suppression on VOICE_COMMUNICATION outputs digital silence in a quiet room; speech played near the
        // phone with the screen off opens the gate at about -50 dB, see the track report.)
        assertTrue("mic silenced by the system: $status", "SILENCED" !in status)
        val screenStayedOff = !power.isInteractive
        wake()

        Log.i(TAG, "screen off 60 s: $beats heartbeats, mic ${(after - before) / MicCapture.SAMPLE_RATE} s")
        assertTrue("screen stayed off for the minute", screenStayedOff)
        assertTrue("service still running", VoiceService.running)
        // The mic kept delivering audio: at least 55 of the 60 s
        val seconds = (after - before) / MicCapture.SAMPLE_RATE
        assertTrue("mic read $seconds s in 60 s with the screen off", seconds >= 55)
        assertTrue("a heartbeat every 10 s: $beats", beats >= 6)
        engine.stop()
    }

    private fun framesRead(): Long {
        val status = VoiceService.status()
        return Regex("""(\d+)s read""").find(status)?.groupValues?.get(1)?.toLong()?.times(MicCapture.SAMPLE_RATE)
            ?: error("no mic status in '$status'")
    }

    private fun wake() {
        val power = context.getSystemService(PowerManager::class.java)
        if (!power.isInteractive) shell("input keyevent 224") // KEYCODE_WAKEUP
    }

    private fun shell(cmd: String): String {
        val pfd: ParcelFileDescriptor = instrumentation.uiAutomation.executeShellCommand(cmd)
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).bufferedReader().readText()
    }

    private fun waitFor(ms: Long, condition: () -> Boolean) {
        val end = SystemClock.uptimeMillis() + ms
        while (!condition() && SystemClock.uptimeMillis() < end) SystemClock.sleep(50)
    }

    private companion object {
        const val TAG = "VoiceServiceTest"
    }
}
