package vn.cicca.livetranslator.engine

import android.Manifest
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/** E5 on the Note 9 (API 29): what the OS recognizers can and cannot do here */
@RunWith(AndroidJUnit4::class)
class OsRecognizerTest {
    @get:Rule val mic: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    private fun catalog(): DeviceRecognizers {
        lateinit var c: DeviceRecognizers
        instrumentation.runOnMainSync { c = DeviceRecognizers(context) }
        return c
    }

    private fun request(kind: String, language: String, mine: Boolean, results: MutableList<Recognized> = mutableListOf()) =
        RecognizerRequest(kind, language, emptyList(), mine, clock = { SystemClock.elapsedRealtime() }, onResult = { results += it })

    @Test fun onDeviceIsReportedUnavailableBelowAndroid13() {
        assumeTrue(Build.VERSION.SDK_INT < RecognizerChoice.FED_AUDIO_API)
        val kinds = catalog().kinds(HOME_LANGUAGE, listOf("en", "ja", "fr"))
        Log.i(TAG, "capabilities on API ${Build.VERSION.SDK_INT}: $kinds")
        assertTrue(kinds.toString(), kinds.values.none { Kinds.OS_ON_DEVICE in it })
        // The board side cannot use OS recognizers here (no PCM feed below API 33)
        assertTrue(kinds.toString(), kinds.filterKeys { it != HOME_LANGUAGE }.values.none { Kinds.OS_ONLINE in it })
        try {
            catalog().create(request(Kinds.OS_ON_DEVICE, HOME_LANGUAGE, mine = true))
            throw AssertionError("expected notReady")
        } catch (e: EngineException) {
            assertEquals("notReady", e.code)
        }
    }

    @Test fun onlineIsOfferedForTheMicSideWhenAServiceExists() {
        val online = SpeechRecognizer.isRecognitionAvailable(context)
        val kinds = catalog().kinds(HOME_LANGUAGE, listOf("en"))
        Log.i(TAG, "recognition service available: $online, kinds: $kinds")
        assertEquals(online, kinds[HOME_LANGUAGE].orEmpty().contains(Kinds.OS_ONLINE))
    }

    @Test fun boardAudioToAnOsRecognizerIsNotReadyBelowAndroid13() {
        assumeTrue(Build.VERSION.SDK_INT < RecognizerChoice.FED_AUDIO_API)
        try {
            catalog().create(request(Kinds.OS_ONLINE, "en", mine = false))
            throw AssertionError("expected notReady")
        } catch (e: EngineException) {
            assertEquals("notReady", e.code)
            assertTrue(e.message.orEmpty(), "Android 13" in e.message.orEmpty())
        }
    }

    @Test fun onlineIsUsedOnlyWhenDartAsksForIt() {
        val c = catalog()
        // Whatever Dart asks for the board side, the mic side never goes online on its own
        assertTrue(c.mineKind(HOME_LANGUAGE, Kinds.WHISPER) != Kinds.OS_ONLINE)
        // Asked for online (Dart holds the consent): a mic-mode recognizer that listens itself
        assumeTrue(SpeechRecognizer.isRecognitionAvailable(context))
        val results = CopyOnWriteArrayList<Recognized>()
        val r = c.create(request(Kinds.OS_ONLINE, HOME_LANGUAGE, mine = true, results))
        assertTrue("below API 33 it owns the mic", r.ownsMic == (Build.VERSION.SDK_INT < RecognizerChoice.FED_AUDIO_API))
        r.listen(true)
        val os = r as OsRecognizer
        val end = SystemClock.uptimeMillis() + 8_000
        while (!os.wasReady && os.lastError == null && results.isEmpty() && SystemClock.uptimeMillis() < end) SystemClock.sleep(100)
        Log.i(TAG, "online recognizer: ready ${os.wasReady}, results $results, last error ${os.lastError?.let { OsRecognizer.errorName(it) }}")
        r.listen(false)
        r.close()
        // It really ran: the service opened its audio, or gave a result, or (offline phone) an error.
        // In a silent room Google's service stays ready without an error for longer than this wait.
        assertFalse("the recognizer never answered", !os.wasReady && os.lastError == null && results.isEmpty())
    }

    private companion object {
        const val TAG = "OsRecognizerTest"
    }
}
