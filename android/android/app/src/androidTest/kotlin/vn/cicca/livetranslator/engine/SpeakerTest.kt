package vn.cicca.livetranslator.engine

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/** E4 on the device: TTS events, the Vietnamese voice check and the system TTS settings screen */
@RunWith(AndroidJUnit4::class)
class SpeakerTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val log = CopyOnWriteArrayList<String>()
    private val sink = object : EngineEventSink {
        override fun ttsStart(id: Long) { log += "start $id" }
        override fun ttsEnd(id: Long) { log += "end $id" }
    }
    private lateinit var speaker: Speaker

    private fun newSpeaker(locale: Locale? = null): Speaker {
        lateinit var s: Speaker
        // TextToSpeech must be created on a thread with a looper; the app creates it on the main thread
        instrumentation.runOnMainSync { s = if (locale == null) Speaker(context, sink) else Speaker(context, sink, locale) }
        waitFor(10_000) { s.isReady }
        return s
    }

    @After fun tearDown() {
        if (::speaker.isInitialized) instrumentation.runOnMainSync { speaker.shutdown() }
    }

    @Test fun speakEmitsStartThenEndInOrder() {
        speaker = newSpeaker(Locale.forLanguageTag(HOME_LANGUAGE))
        val voice = speaker.hasVoice()
        Log.i(TAG, "Vietnamese voice installed: $voice")
        speaker.speak("Xin chào", 1)
        speaker.speak("Cảm ơn", 2)
        waitFor(20_000) { "end 2" in log }
        Log.i(TAG, "events: $log")
        // Each id ends exactly once; ends arrive in queue order
        assertEquals(1, log.count { it == "end 1" })
        assertEquals(1, log.count { it == "end 2" })
        assertTrue(log.indexOf("end 1") < log.indexOf("end 2"))
        // A start, when the engine reports one, comes before its end
        listOf(1L, 2L).forEach { id ->
            val s = log.indexOf("start $id")
            if (s >= 0) assertTrue(s < log.indexOf("end $id"))
        }
        if (voice) assertTrue("with a voice installed both utterances start: $log", "start 1" in log && "start 2" in log)
    }

    /** The listener path with a voice the phone has (the Note 9 has no Vietnamese one): start, then end, in queue order */
    @Test fun withAVoiceEachUtteranceStartsThenEnds() {
        speaker = newSpeaker(Locale.ENGLISH)
        assertTrue("the phone needs an English voice for this test", speaker.hasVoice())
        speaker.speak("One", 21)
        speaker.speak("Two", 22)
        waitFor(20_000) { "end 22" in log }
        Log.i(TAG, "events: $log")
        assertEquals(listOf("start 21", "end 21", "start 22", "end 22"), log.toList())
    }

    @Test fun stopEndsEveryQueuedUtterance() {
        // English voice, so the utterances really sit in the engine's queue when stop() comes
        speaker = newSpeaker(Locale.ENGLISH)
        speaker.speak("One two three four five six seven eight nine ten eleven twelve", 10)
        speaker.speak("Thirteen fourteen", 11)
        speaker.speak("Fifteen", 12)
        waitFor(5_000) { "start 10" in log }
        speaker.stop()
        waitFor(5_000) { log.count { it.startsWith("end") } >= 3 }
        Log.i(TAG, "events: $log")
        listOf(10L, 11L, 12L).forEach { assertEquals(log.toString(), 1, log.count { e -> e == "end $it" }) }
        // Stopped before they could play: the queued ones never started
        assertTrue(log.toString(), log.none { it == "start 11" || it == "start 12" })
    }

    @Test fun missingIncludesTtsVoiceExactlyWhenNoVietnameseVoice() {
        speaker = newSpeaker()
        val voice = speaker.hasVoice(HOME_LANGUAGE)
        val items = MissingItems.compute(
            translation = emptyList(), speechModels = emptyList(), vietnameseVoice = voice, home = HOME_LANGUAGE,
        )
        Log.i(TAG, "Vietnamese voice $voice → missing $items")
        assertEquals(!voice, items.any { it.kind == MissingKind.TTS_VOICE })
    }

    /** The engine gives the voice language later (capabilities(home), the pair); none before that */
    @Test fun theVoiceLanguageComesFromTheCaller() {
        speaker = newSpeaker()
        assertFalse("no language yet: no voice", speaker.hasVoice())
        assertTrue("the phone needs an English voice for this test", speaker.hasVoice("en"))
        assertTrue(speaker.hasVoice())
        speaker.speak("One", 31)
        waitFor(20_000) { "end 31" in log }
        assertEquals(listOf("start 31", "end 31"), log.toList())
    }

    @Test fun openTtsSettingsShowsTheSystemScreen() {
        Speaker.openTtsSettings(context)
        var top = ""
        waitFor(5_000) {
            top = shell("dumpsys activity activities").lineSequence()
                .firstOrNull { "mResumedActivity" in it || "ResumedActivity:" in it }.orEmpty()
            "Tts" in top || "TextToSpeech" in top
        }
        Log.i(TAG, "resumed: $top")
        assertTrue("TTS settings not on top: $top", "Tts" in top || "TextToSpeech" in top)
        shell("input keyevent 4") // back
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
        const val TAG = "SpeakerTest"
    }
}
