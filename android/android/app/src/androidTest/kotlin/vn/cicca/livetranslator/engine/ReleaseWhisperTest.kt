package vn.cicca.livetranslator.engine

import android.Manifest
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList

/**
 * One Whisper transcription through the engine, meant to run against the R8-minified RELEASE app
 * (`./gradlew -PtestBuildType=release installRelease installReleaseAndroidTest`, then `am instrument`).
 * It touches only the engine's public surface (NativeVoiceEngine, EngineEventSink, the pigeon messages)
 * so R8 can treat everything behind it, the JNI path included, exactly as in a real release build.
 * Needs ggml-base-q5_1.bin and en.wav pushed to /sdcard/Android/data/vn.cicca.livetranslator/files/.
 */
@RunWith(AndroidJUnit4::class)
class ReleaseWhisperTest {
    @get:Rule val mic: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    @Test fun boardAudioIsTranscribed() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val pushed = context.getExternalFilesDir(null)!!
        val model = File(File(context.filesDir, "models").apply { mkdirs() }, "ggml-base-q5_1.bin")
        if (!model.isFile) {
            val src = File(pushed, model.name)
            assumeTrue("push the model to $src", src.isFile)
            src.copyTo(model)
        }
        val pcm = wavData(File(pushed, "en.wav"))

        val theirs = CopyOnWriteArrayList<TheirsMsg>()
        val sink = object : EngineEventSink {
            override fun theirs(msg: TheirsMsg) { theirs += msg }
        }
        lateinit var engine: NativeVoiceEngine
        instrumentation.runOnMainSync { engine = NativeVoiceEngine(context, sink) }
        try {
            engine.start(PairMsg(HOME_LANGUAGE, "en", 3), "whisper", emptyList())
            for (at in pcm.indices step 640) engine.feedTheirAudio(pcm.copyOfRange(at, minOf(at + 640, pcm.size)), 16_000)
            val end = SystemClock.uptimeMillis() + 30_000
            while (theirs.isEmpty() && SystemClock.uptimeMillis() < end) SystemClock.sleep(100)
            Log.i("ReleaseWhisperTest", "theirs: $theirs")
            assertEquals(1, theirs.size)
            assertTrue(theirs[0].text.contains("station", ignoreCase = true))
        } finally {
            instrumentation.runOnMainSync { engine.shutdown() }
        }
    }

    /** The data chunk of a 16-bit mono WAV: already little-endian PCM */
    private fun wavData(f: File): ByteArray {
        assumeTrue("push ${f.name}", f.isFile)
        val bytes = f.readBytes()
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        b.position(12)
        while (b.remaining() >= 8) {
            val id = ByteArray(4).also { b.get(it) }.toString(Charsets.US_ASCII)
            val size = b.int
            if (id == "data") return bytes.copyOfRange(b.position(), b.position() + size)
            b.position(b.position() + size + (size and 1))
        }
        error("no data chunk in ${f.name}")
    }
}
