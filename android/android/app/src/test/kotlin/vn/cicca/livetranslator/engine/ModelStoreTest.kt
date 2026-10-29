package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.MessageDigest

class ModelStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val model = ByteArray(300_000) { (it * 31 % 251).toByte() }
    private val sha = MessageDigest.getInstance("SHA-256").digest(model).joinToString("") { "%02x".format(it) }

    private fun store(bytes: ByteArray = model, expected: String = sha, online: Boolean = true) = ModelStore(
        dir = tmp.root,
        spec = ModelStore.Spec("test.bin", "https://example.invalid/test.bin", expected),
        isOnline = { online },
        open = { ModelStore.Download(ByteArrayInputStream(bytes), bytes.size.toLong()) },
    )

    @Test fun downloadVerifiesAndKeepsAMatchingModel() = kotlinx.coroutines.runBlocking {
        val s = store()
        assertFalse(s.present())
        val progress = mutableListOf<Double>()
        s.download { progress += it }
        assertTrue(s.present())
        assertTrue(s.verified())
        assertEquals(0.0, progress.first(), 0.0)
        assertEquals(1.0, progress.last(), 0.0)
        assertTrue("progress grows", progress.zipWithNext().all { (a, b) -> b >= a })
    }

    @Test fun shaMismatchRefusesAndDeletesTheDownload() = kotlinx.coroutines.runBlocking {
        val tampered = model.copyOf().also { it[1234] = (it[1234] + 1).toByte() }
        val s = store(bytes = tampered)
        try {
            s.download {}
            throw AssertionError("expected downloadFailed")
        } catch (e: FlutterError) {
            assertEquals("downloadFailed", e.code)
            assertTrue(e.message.orEmpty(), "SHA-256" in e.message.orEmpty())
        }
        assertFalse(s.present())
        assertEquals("no file left behind", 0, tmp.root.listFiles()!!.size)
    }

    @Test fun aFileAlreadyOnDiskWithTheWrongHashIsRefusedAndDeleted() {
        val s = store()
        s.file.writeBytes(model.copyOf(model.size - 1))
        assertFalse(s.verified())
        assertFalse(s.file.exists())
    }

    @Test fun offlineDownloadFailsAtOnce() = kotlinx.coroutines.runBlocking {
        try {
            store(online = false).download {}
            throw AssertionError("expected downloadFailed")
        } catch (e: FlutterError) {
            assertEquals("downloadFailed", e.code)
        }
    }

    @Test fun networkErrorLeavesNothingBehind() = kotlinx.coroutines.runBlocking {
        val s = ModelStore(
            tmp.root, ModelStore.Spec("test.bin", "https://example.invalid/test.bin", sha), isOnline = { true },
            open = { throw IOException("connection reset") },
        )
        try {
            s.download {}
            throw AssertionError("expected downloadFailed")
        } catch (e: FlutterError) {
            assertEquals("downloadFailed", e.code)
        }
        assertEquals(0, tmp.root.listFiles()!!.size)
    }

    @Test fun theShippedModelIsPinned() {
        assertEquals("ggml-base-q5_1.bin", ModelStore.WHISPER_BASE.fileName)
        assertEquals("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin", ModelStore.WHISPER_BASE.url)
        assertEquals("422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", ModelStore.WHISPER_BASE.sha256)
    }
}
