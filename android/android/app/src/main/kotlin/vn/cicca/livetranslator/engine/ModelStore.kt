package vn.cicca.livetranslator.engine

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Whisper models on disk: downloaded on first use over HTTPS and checked by SHA-256 before they are kept
 * and before they are loaded (constraints). A file whose hash does not match is refused and deleted.
 */
class ModelStore(
    dir: File,
    val spec: Spec = WHISPER_BASE,
    private val isOnline: () -> Boolean,
    private val open: (URL) -> Download = ::httpGet,
) {
    data class Spec(val fileName: String, val url: String, val sha256: String)

    /** An open download: the body and its length (-1 when unknown) */
    class Download(val body: InputStream, val length: Long)

    val file = File(dir, spec.fileName)
    private val lock = Any()
    /** Size and mtime of the file last verified in this process (hashing 60 MB takes a moment) */
    private var verifiedStamp: Pair<Long, Long>? = null

    fun present(): Boolean = file.isFile

    /** True when the file exists and its SHA-256 matches; a mismatching file is deleted */
    fun verified(): Boolean = synchronized(lock) {
        if (!file.isFile) return false
        val stamp = file.length() to file.lastModified()
        if (stamp == verifiedStamp) return true
        val actual = sha256(file)
        if (actual != spec.sha256) {
            Log.w(TAG, "${spec.fileName}: SHA-256 $actual does not match ${spec.sha256}; deleted")
            file.delete()
            verifiedStamp = null
            return false
        }
        verifiedStamp = stamp
        true
    }

    /** Downloads the model unless a verified copy is already there. Progress 0…1 */
    suspend fun download(progress: (Double) -> Unit) = withContext(Dispatchers.IO) {
        progress(0.0)
        if (verified()) {
            progress(1.0)
            return@withContext
        }
        if (!isOnline()) throw EngineErrors.downloadFailed("no network")
        file.parentFile?.mkdirs()
        val part = File(file.parentFile, "${spec.fileName}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val download = open(URL(spec.url))
            var done = 0L
            var lastReport = 0.0
            download.body.use { body ->
                part.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = body.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        digest.update(buffer, 0, n)
                        done += n
                        if (download.length > 0) {
                            val p = done.toDouble() / download.length
                            if (p - lastReport >= 0.01) {
                                lastReport = p
                                progress(minOf(p, 0.99))
                            }
                        }
                    }
                }
            }
            val actual = digest.digest().hex()
            if (actual != spec.sha256) {
                throw EngineErrors.downloadFailed("${spec.fileName}: SHA-256 mismatch ($actual), refused")
            }
            synchronized(lock) {
                if (!part.renameTo(file)) throw EngineErrors.downloadFailed("could not store ${spec.fileName}")
                verifiedStamp = file.length() to file.lastModified()
            }
            Log.i(TAG, "${spec.fileName}: downloaded and verified ($done bytes)")
            progress(1.0)
        } catch (e: EngineException) {
            part.delete()
            throw e
        } catch (e: Exception) {
            part.delete()
            throw EngineErrors.downloadFailed("${spec.fileName}: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "ModelStore"

        /** Whisper base, multilingual, 5-bit quantized (59,707,625 bytes); hash taken from the file on 2026-10-26 */
        val WHISPER_BASE = Spec(
            fileName = "ggml-base-q5_1.bin",
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
            sha256 = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
        )

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().hex()
        }

        private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

        private fun httpGet(url: URL): Download {
            val c = url.openConnection() as HttpURLConnection
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            c.instanceFollowRedirects = true
            val code = c.responseCode
            if (code != HttpURLConnection.HTTP_OK) throw java.io.IOException("HTTP $code")
            return Download(c.inputStream, c.contentLengthLong)
        }
    }
}
