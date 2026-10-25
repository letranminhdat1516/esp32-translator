package vn.cicca.livetranslator.engine

import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * E3 on the device. [downloadThenTranslate] needs the network. [translatesOffline] runs only with the
 * instrumentation argument `offline=true`, after Wi-Fi and data are turned off, and fails if any network is up.
 */
@RunWith(AndroidJUnit4::class)
class MlKitTranslatorTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val home = HOME_LANGUAGE
    private val other = "en"

    @Test fun downloadThenTranslate() = runBlocking {
        val translator = MlKitTranslator({ context.isOnline() })
        val progress = mutableListOf<Double>()
        if (translator.missing(home, other).isNotEmpty()) {
            translator.download(home, other) { progress += it }
            assertEquals(listOf(0.0, 1.0), progress)
        }
        assertTrue(translator.missing(home, other).isEmpty())
        val vi = translator.translate("Good morning, how are you?", other, home)
        Log.i(TAG, "en→vi: $vi")
        assertTrue(vi.isNotBlank())
        assertNotEquals("Good morning, how are you?", vi)
    }

    @Test fun translatesOffline() = runBlocking {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        // Runs only when asked (-e offline true), and then the network must really be off
        assumeTrue(InstrumentationRegistry.getArguments().getString("offline") == "true")
        assertNull("this test must run with the network off", cm.activeNetwork)
        val translator = MlKitTranslator({ context.isOnline() })
        assertTrue("models must already be downloaded", translator.missing(home, other).isEmpty())
        val vi = translator.translate("Where is the train station?", other, home)
        val en = translator.translate("Cảm ơn bạn rất nhiều", home, other)
        Log.i(TAG, "offline en→vi: $vi | vi→en: $en")
        assertTrue(vi.isNotBlank() && vi != "Where is the train station?")
        assertTrue(en.isNotBlank() && en != "Cảm ơn bạn rất nhiều")
    }

    @Test fun missingModelIsNotReadyNotADownload() = runBlocking {
        // A language whose model is not on the phone: translate refuses instead of fetching it
        val translator = MlKitTranslator({ context.isOnline() })
        val absent = listOf("is", "mt", "cy", "ga").firstOrNull { it !in translator.downloaded() }
        assumeTrue(absent != null)
        try {
            translator.translate("hello", other, absent!!)
            throw AssertionError("expected notReady")
        } catch (e: FlutterError) {
            assertEquals("notReady", e.code)
        }
    }

    @Test fun downloadWithoutNetworkFailsInsteadOfWaiting() = runBlocking {
        val translator = MlKitTranslator(isOnline = { false })
        val absent = listOf("is", "mt", "cy", "ga").first { it !in translator.downloaded() }
        val progress = mutableListOf<Double>()
        try {
            translator.download(home, absent) { progress += it }
            throw AssertionError("expected downloadFailed")
        } catch (e: FlutterError) {
            assertEquals("downloadFailed", e.code)
        }
        assertEquals(listOf(0.0), progress)
    }

    private companion object {
        const val TAG = "MlKitTranslatorTest"
    }
}
