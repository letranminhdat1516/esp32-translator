package vn.cicca.livetranslator.engine

import android.Manifest
import android.content.Context
import androidx.test.rule.GrantPermissionRule
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList

/**
 * E6 on the Note 9. The model and two 5 s clips (macOS `say`, 16 kHz mono WAV) are pushed to the app's
 * external files dir first, because the phone has no network:
 *   adb push ggml-base-q5_1.bin en.wav vi.wav /sdcard/Android/data/vn.cicca.livetranslator/files/
 * The model is copied into the app's model store and goes through the same SHA-256 check as a download.
 */
@RunWith(AndroidJUnit4::class)
class WhisperTest {
    @get:Rule val mic: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val pushed: File get() = context.getExternalFilesDir(null)!!

    private fun store(): ModelStore {
        val s = ModelStore(File(context.filesDir, "models"), isOnline = { false })
        if (!s.present()) {
            val src = File(pushed, ModelStore.WHISPER_BASE.fileName)
            assumeTrue("push the model to $src", src.isFile)
            s.file.parentFile!!.mkdirs()
            src.copyTo(s.file)
        }
        return s
    }

    @Test fun libraryIsBuiltForThisPhone() {
        assertTrue(WhisperNative.loaded)
        Log.i(TAG, WhisperNative.systemInfo())
    }

    @Test fun shaMismatchRefusesTheModel() {
        val dir = File(context.cacheDir, "bad-model").apply { deleteRecursively(); mkdirs() }
        val s = ModelStore(dir, isOnline = { false })
        s.file.writeBytes(ByteArray(4096) { 7 })
        val model = WhisperModel(s)
        assertFalse("a model with the wrong SHA-256 is not loaded", model.load())
        assertFalse("and it is deleted", s.file.exists())
    }

    @Test fun pinnedModelPassesItsCheckAndLoads() {
        val model = WhisperModel(store())
        assertTrue(model.store.verified())
        assertTrue(model.load())
    }

    @Test fun realTimeFactorOnFiveSecondClips() {
        val model = WhisperModel(store())
        assertTrue(model.load())
        val en = model.transcribe(wav("en.wav"), "en", null)
        val vi = model.transcribe(wav(HOME_LANGUAGE + ".wav"), HOME_LANGUAGE, null)
        Log.i(TAG, "RTF en %.2f (%.1f s audio, %.2f s, confidence %.2f) \"%s\"".format(en.rtf, en.audioSeconds, en.seconds, en.confidence, en.text))
        Log.i(TAG, "RTF vi %.2f (%.1f s audio, %.2f s, confidence %.2f) \"%s\"".format(vi.rtf, vi.audioSeconds, vi.seconds, vi.confidence, vi.text))
        assertNotNull(en.text)
        assertNotNull(vi.text)
        assertTrue(en.text, en.text!!.contains("station", ignoreCase = true))
        // The synthetic voice's "ga tàu" comes out as "gà tạo"; the sentence is clearly Vietnamese
        assertTrue(vi.text, vi.text!!.contains("Xin lỗi", ignoreCase = true) && vi.text!!.contains("đường"))
    }

    /** Digital silence: skipped before Whisper (it says "you" on zeros, with a low no_speech_prob) */
    @Test fun silenceGivesNothing() {
        val model = WhisperModel(store())
        val t = model.transcribe(FloatArray(3 * 16_000), "en", null)
        assertNull(t.text)
        assertEquals("not even transcribed", 0, t.segments.size)
    }

    /** Quiet noise passes the silence guard: Whisper runs and the hallucination filter must drop the result */
    @Test fun noiseGivesNothing() {
        val model = WhisperModel(store())
        var seed = 12345L
        val noise = FloatArray(3 * 16_000) {
            seed = seed * 6364136223846793005L + 1442695040888963407L
            ((seed ushr 40).toFloat() / (1 shl 24) * 2 - 1) * 0.0056f // about -45 dB
        }
        for (language in listOf("en", HOME_LANGUAGE)) {
            val t = model.transcribe(noise, language, null)
            Log.i(TAG, "noise ($language) → segments ${t.segments} → ${t.text}")
            assertNull("noise produced \"${t.text}\"", t.text)
        }
    }

    /** The board side: a pause in the board's audio ends the utterance, which yields one final */
    @Test fun boardPauseEndsTheUtterance() {
        val model = WhisperModel(store())
        val results = CopyOnWriteArrayList<Recognized>()
        val start = SystemClock.elapsedRealtime()
        val r = WhisperRecognizer(
            model,
            RecognizerRequest(Kinds.WHISPER, "en", emptyList(), mine = false, clock = { SystemClock.elapsedRealtime() - start }, onResult = { results += it }),
        )
        val pcm = VoiceGate.toPcm16(wav("en.wav"))
        // As the board link delivers it: 20 ms packets
        pcm.toList().chunked(320).forEach { r.audio(it.toShortArray(), 16_000) }
        val end = SystemClock.uptimeMillis() + 30_000
        while (results.isEmpty() && SystemClock.uptimeMillis() < end) SystemClock.sleep(100)
        r.close()
        Log.i(TAG, "board utterance → $results")
        assertEquals(1, results.size)
        assertTrue(results[0].final)
        assertTrue(results[0].text.contains("station", ignoreCase = true))
    }

    /** Without the model, both languages of the pair need it on this phone (no on-device OS recognizer) */
    @Test fun missingModelIsReportedForBothSides() {
        val noModel = object : WhisperSupport {
            override val libraryLoaded = true
            override fun modelPresent() = false
            override fun create(request: RecognizerRequest): UtteranceRecognizer = throw EngineErrors.notReady("no model")
        }
        lateinit var c: DeviceRecognizers
        InstrumentationRegistry.getInstrumentation().runOnMainSync { c = DeviceRecognizers(context, noModel) }
        assertEquals(listOf(HOME_LANGUAGE, "en"), c.speechModelsMissing(PairMsg(HOME_LANGUAGE, "en", 1)))
    }

    /** End to end through the engine: capabilities, missing, start with Whisper, board PCM → onTheirs */
    @Test fun engineTurnsBoardAudioIntoTheirs() = runBlocking {
        store() // model in place
        val theirs = CopyOnWriteArrayList<TheirsMsg>()
        val sink = object : EngineEventSink {
            override fun theirs(msg: TheirsMsg) { theirs += msg }
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        lateinit var engine: NativeVoiceEngine
        instrumentation.runOnMainSync { engine = NativeVoiceEngine(context, sink) }
        try {
            val caps = engine.capabilities(HOME_LANGUAGE)
            val kinds = caps.recognizers.associate { it.language to it.kinds }
            Log.i(TAG, "capabilities: vi=${kinds[HOME_LANGUAGE]} en=${kinds["en"]} translatable=${caps.translatable.size} voice=${caps.vietnameseVoice}")
            assertEquals(Kinds.WHISPER, kinds[HOME_LANGUAGE]?.first())
            assertEquals(listOf(Kinds.WHISPER), kinds["en"])
            val pair = PairMsg(HOME_LANGUAGE, "en", 7)
            val missing = engine.missing(pair)
            Log.i(TAG, "missing: $missing")
            assertTrue("model present: no speechModel item", missing.none { it.kind == MissingKind.SPEECH_MODEL })

            engine.start(pair, Kinds.WHISPER, emptyList())
            // 16-bit little-endian PCM in 20 ms packets, as the Dart side forwards the board's audio
            val pcm = VoiceGate.toPcm16(wav("en.wav"))
            val bytes = ByteBuffer.allocate(pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                .apply { asShortBuffer().put(pcm) }.array()
            bytes.toList().chunked(640).forEach { engine.feedTheirAudio(it.toByteArray(), 16_000) }
            val end = SystemClock.uptimeMillis() + 30_000
            while (theirs.isEmpty() && SystemClock.uptimeMillis() < end) SystemClock.sleep(100)
            Log.i(TAG, "theirs: $theirs")
            assertEquals(1, theirs.size)
            assertEquals(7L, theirs[0].generation)
            assertTrue(theirs[0].text.contains("station", ignoreCase = true))
            assertTrue((theirs[0].confidence ?: 0.0) > 0.5)
        } finally {
            instrumentation.runOnMainSync { engine.shutdown() }
        }
    }

    /** Reads a 16-bit mono WAV (finds the data chunk) as floats */
    private fun wav(name: String): FloatArray {
        val f = File(pushed, name)
        assumeTrue("push $name to $pushed", f.isFile)
        val b = ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        b.position(12)
        while (b.remaining() >= 8) {
            val id = ByteArray(4).also { b.get(it) }.toString(Charsets.US_ASCII)
            val size = b.int
            if (id == "data") {
                val shorts = ShortArray(size / 2) { b.short }
                return VoiceGate.toFloats(shorts)
            }
            b.position(b.position() + size + (size and 1))
        }
        error("no data chunk in $name")
    }

    private companion object {
        const val TAG = "WhisperTest"
    }
}
