package vn.cicca.livetranslator.engine

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The VoiceEngine TurboModule (spec: android/src/engine/NativeVoiceEngine.ts) over [NativeVoiceEngine].
 *
 * - Calls run in coroutines on the main thread; the slow ones (capabilities, missing, download, translate,
 *   building a session) move to an IO thread inside the engine and resolve back on the main thread.
 * - `feedTheirAudio` (about 50 calls/s) runs on the calling thread: base64 → samples → the recognizer's queue.
 *   It rejects with `notReady` whenever the their-side recognizer is not running (never started, stopped, or
 *   given up after a fatal error) until the next successful `start` ([TheirFeed]); the JS controller reads
 *   that as "their recognizer died".
 * - Failures reject with `code` = an `EngineErrorCode` name ([EngineWire.errorCode]).
 * - Events go out through the generated emitters, in order, from the main thread.
 */
class VoiceEngineModule(context: ReactApplicationContext) : NativeVoiceEngineSpec(context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val main = Handler(Looper.getMainLooper())

    private val sink = object : EngineEventSink {
        override fun mine(msg: MineMsg) = post { emitMine(writableMap(EngineWire.mine(msg))) }
        override fun theirs(msg: TheirsMsg) = post { emitTheirs(writableMap(EngineWire.theirs(msg))) }
        override fun gate(open: Boolean) = post { emitGate(open) }
        override fun ttsStart(id: Long) = post { emitTtsStart(id.toDouble()) }
        override fun ttsEnd(id: Long) = post { emitTtsEnd(id.toDouble()) }
        override fun audioSession(msg: AudioSessionMsg) =
            post { emitAudioSession(writableMap(EngineWire.audioSession(msg))) }
        override fun download(msg: DownloadMsg) = post { emitDownload(writableMap(EngineWire.download(msg))) }
    }

    private val engine: NativeVoiceEngine get() = engineHolder.value
    private val engineHolder = lazy {
        NativeVoiceEngine(context.applicationContext, sink).also { e ->
            // Runtime permissions through the React activity; without one, the request is answered "denied"
            e.permissions.requester = PermissionRequester { permissions, code ->
                val activity = reactApplicationContext.currentActivity as? PermissionAwareActivity
                if (activity == null) {
                    e.permissions.onRequestPermissionsResult(code, permissions, IntArray(0))
                } else {
                    activity.requestPermissions(permissions, code, PermissionListener { c, p, g ->
                        e.permissions.onRequestPermissionsResult(c, p, g)
                    })
                }
            }
        }
    }

    // --- events (protected emitters, wrapped for the sink) ---------------------------------------

    private fun post(emit: () -> Unit) {
        main.post {
            try {
                emit()
            } catch (e: Exception) {
                Log.w(TAG, "event not delivered: ${e.message}")
            }
        }
    }

    private fun emitMine(m: WritableMap) = emitOnMine(m)
    private fun emitTheirs(m: WritableMap) = emitOnTheirs(m)
    private fun emitGate(open: Boolean) = emitOnGate(open)
    private fun emitTtsStart(id: Double) = emitOnTtsStart(id)
    private fun emitTtsEnd(id: Double) = emitOnTtsEnd(id)
    private fun emitAudioSession(m: WritableMap) = emitOnAudioSession(m)
    private fun emitDownload(m: WritableMap) = emitOnDownload(m)

    // --- calls ------------------------------------------------------------------------------------

    /**
     * Runs [call] on the main thread; its result resolves [promise], a failure rejects with an EngineError
     * code. A call cut short by [invalidate] (scope cancelled, even before it started) rejects with notReady,
     * so no JS promise is left pending.
     */
    private fun run(promise: Promise, fallback: String, call: suspend () -> Any?) {
        val settled = AtomicBoolean(false)
        val job = scope.launch {
            val result = try {
                call()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (settled.compareAndSet(false, true)) {
                    promise.reject(EngineWire.errorCode(e, fallback), e.message ?: e.javaClass.simpleName, e)
                }
                return@launch
            }
            if (settled.compareAndSet(false, true)) promise.resolve(result)
        }
        job.invokeOnCompletion { cause ->
            if (cause is CancellationException && settled.compareAndSet(false, true)) {
                promise.reject(NOT_READY, "the voice engine was shut down", cause)
            }
        }
    }

    override fun capabilities(home: String, promise: Promise) =
        run(promise, NOT_READY) { writableMap(EngineWire.capabilities(engine.capabilities(home))) }

    override fun missing(pair: ReadableMap, promise: Promise) = run(promise, NOT_READY) {
        val list = engine.missing(EngineWire.pair(pair.toHashMap()))
        writableArray(list.map(EngineWire::missing))
    }

    override fun download(item: ReadableMap, promise: Promise) = run(promise, DOWNLOAD_FAILED) {
        engine.download(EngineWire.missingItem(item.toHashMap()))
        null
    }

    override fun start(pair: ReadableMap, recognizerX: String, hints: ReadableArray, promise: Promise) =
        run(promise, NOT_READY) {
            engine.start(EngineWire.pair(pair.toHashMap()), recognizerX, strings(hints))
            null
        }

    override fun stop(promise: Promise) = run(promise, NOT_READY) { engine.stop(); null }

    override fun micOn(on: Boolean, promise: Promise) = run(promise, NOT_READY) { engine.micOn(on); null }

    override fun feedTheirAudio(pcm16leBase64: String, sampleRate: Double, promise: Promise) {
        try {
            engine.feedTheirAudio(EngineWire.pcm16(pcm16leBase64), EngineWire.int32(sampleRate).toInt())
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject(EngineWire.errorCode(e, NOT_READY), e.message ?: e.javaClass.simpleName, e)
        }
    }

    override fun translate(text: String, from: String, to: String, promise: Promise) =
        run(promise, TRANSLATE_FAILED) { engine.translate(text, from, to) }

    override fun speak(text: String, id: Double, promise: Promise) =
        run(promise, NOT_READY) { engine.speak(text, EngineWire.int32(id)); null }

    override fun stopSpeaking(promise: Promise) = run(promise, NOT_READY) { engine.stopSpeaking(); null }

    override fun setHints(hints: ReadableArray, promise: Promise) =
        run(promise, NOT_READY) { engine.setHints(strings(hints)); null }

    override fun openTtsSettings(promise: Promise) = run(promise, NOT_READY) { engine.openTtsSettings(); null }

    override fun invalidate() {
        scope.cancel()
        // Only shut down an engine that exists (the lazy getter would build one)
        if (engineHolder.isInitialized()) engine.shutdown()
        super.invalidate()
    }

    private companion object {
        const val TAG = "VoiceEngineModule"
        const val NOT_READY = "notReady"
        const val TRANSLATE_FAILED = "translateFailed"
        const val DOWNLOAD_FAILED = "downloadFailed"

        fun strings(array: ReadableArray): List<String> = (0 until array.size()).mapNotNull { array.getString(it) }

        @Suppress("UNCHECKED_CAST")
        fun writableMap(map: Map<String, Any?>): WritableMap = Arguments.createMap().apply {
            for ((key, value) in map) {
                when (value) {
                    null -> putNull(key)
                    is String -> putString(key, value)
                    is Boolean -> putBoolean(key, value)
                    is Number -> putDouble(key, value.toDouble())
                    is Map<*, *> -> putMap(key, writableMap(value as Map<String, Any?>))
                    is List<*> -> putArray(key, writableArray(value))
                    else -> throw IllegalArgumentException("$key: cannot send ${value.javaClass}")
                }
            }
        }

        @Suppress("UNCHECKED_CAST")
        fun writableArray(list: List<*>): WritableArray = Arguments.createArray().apply {
            for (value in list) {
                when (value) {
                    null -> pushNull()
                    is String -> pushString(value)
                    is Boolean -> pushBoolean(value)
                    is Number -> pushDouble(value.toDouble())
                    is Map<*, *> -> pushMap(writableMap(value as Map<String, Any?>))
                    is List<*> -> pushArray(writableArray(value))
                    else -> throw IllegalArgumentException("cannot send ${value.javaClass}")
                }
            }
        }
    }
}
