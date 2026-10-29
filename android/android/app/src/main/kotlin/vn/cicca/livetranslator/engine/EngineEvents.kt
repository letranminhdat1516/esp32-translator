package vn.cicca.livetranslator.engine

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Where native components send their events. The app uses [PigeonEventSink]; tests record them.
 * Any thread may call these.
 */
interface EngineEventSink {
    fun mine(msg: MineMsg) {}
    fun theirs(msg: TheirsMsg) {}
    fun gate(open: Boolean) {}
    fun ttsStart(id: Long) {}
    fun ttsEnd(id: Long) {}
    fun audioSession(msg: AudioSessionMsg) {}
    fun download(msg: DownloadMsg) {}
}

/** Sends events to Dart through the generated [VoiceEngineEvents], on the main thread and in call order. */
class PigeonEventSink(messenger: BinaryMessenger) : EngineEventSink {
    private val events = VoiceEngineEvents(messenger)
    private val main = Handler(Looper.getMainLooper())
    // Main.immediate keeps the order of posts; each send is fire-and-forget
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private fun send(name: String, call: suspend VoiceEngineEvents.() -> Unit) {
        main.post {
            scope.launch {
                try {
                    events.call()
                } catch (e: Exception) {
                    // No Dart listener (engine detached): drop the event
                    Log.w(TAG, "event $name not delivered: ${e.message}")
                }
            }
        }
    }

    override fun mine(msg: MineMsg) = send("mine") { onMine(msg) }
    override fun theirs(msg: TheirsMsg) = send("theirs") { onTheirs(msg) }
    override fun gate(open: Boolean) = send("gate") { onGate(open) }
    override fun ttsStart(id: Long) = send("ttsStart") { onTtsStart(id) }
    override fun ttsEnd(id: Long) = send("ttsEnd") { onTtsEnd(id) }
    override fun audioSession(msg: AudioSessionMsg) = send("audioSession") { onAudioSession(msg) }
    override fun download(msg: DownloadMsg) = send("download") { onDownload(msg) }

    private companion object {
        const val TAG = "PigeonEventSink"
    }
}
