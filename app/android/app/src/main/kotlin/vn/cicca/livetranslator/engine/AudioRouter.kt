package vn.cicca.livetranslator.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi

/** An audio input the router can choose */
data class InputDevice(val id: Int, val type: Int, val name: String) {
    val isBluetooth: Boolean get() = type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    val isWired: Boolean
        get() = type == AudioDeviceInfo.TYPE_WIRED_HEADSET || type == AudioDeviceInfo.TYPE_USB_HEADSET
    val isHeadset: Boolean get() = isBluetooth || isWired
}

/**
 * The input devices and the Bluetooth SCO link. Injectable so the route logic can be tested on the
 * phone without a headset ([AndroidAudioDeviceSource] is the real one).
 */
interface AudioDeviceSource {
    fun inputs(): List<InputDevice>
    /** Calls [onChange] (any thread) when the inputs change or the SCO link goes up or down */
    fun start(onChange: () -> Unit)
    fun stop()
    /** Asks for the SCO link to [device]; [scoConnected] turns true when it is up */
    fun connectSco(device: InputDevice)
    fun disconnectSco()
    val scoConnected: Boolean
}

/**
 * Audio session for a conversation (P7): communication mode (echo cancellation on the VOICE_COMMUNICATION
 * source), other apps ducked with GAIN_TRANSIENT_MAY_DUCK, the Bluetooth headset mic over SCO when one is
 * connected, else the phone mic ("mic điện thoại" chip, ARCHITECTURE §6).
 *
 * Emits `audioSession(routeChanged, headset|phoneMic)` at start and on every change (Review Focus 4: the
 * headset disconnecting falls back to the phone mic with an event), and interrupted/resumed when another
 * app (a call) takes audio focus.
 */
class AudioRouter(
    context: Context,
    private val events: EngineEventSink,
    private val devices: AudioDeviceSource = AndroidAudioDeviceSource(context),
    private val onRoute: (AudioRoute) -> Unit = {},
) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val lock = Any()
    private var running = false
    private var scoRequestedFor: Int? = null
    private var focus: AudioFocusRequest? = null
    private var interrupted = false

    @Volatile var route: AudioRoute? = null
        private set

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> setInterrupted(true)
            AudioManager.AUDIOFOCUS_GAIN -> setInterrupted(false)
        }
    }

    fun start() {
        synchronized(lock) {
            if (running) return
            running = true
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build()
            focus = request
            val granted = audio.requestAudioFocus(request)
            Log.i(TAG, "audio focus ${if (granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) "granted" else "refused ($granted)"}")
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        devices.start { evaluate() }
        evaluate()
    }

    fun stop() {
        synchronized(lock) {
            if (!running) return
            running = false
            devices.stop()
            devices.disconnectSco()
            scoRequestedFor = null
            focus?.let { audio.abandonAudioFocusRequest(it) }
            focus = null
            audio.mode = AudioManager.MODE_NORMAL
            route = null
            interrupted = false
        }
        Log.i(TAG, "audio session ended")
    }

    /** Picks the route from the current inputs; asks for SCO once per headset connection */
    private fun evaluate() {
        val changed: AudioRoute?
        synchronized(lock) {
            if (!running) return
            val inputs = devices.inputs()
            val bluetooth = inputs.firstOrNull { it.isBluetooth }
            val wired = inputs.firstOrNull { it.isWired }
            if (bluetooth == null) {
                if (scoRequestedFor != null) devices.disconnectSco()
                scoRequestedFor = null
            } else if (scoRequestedFor != bluetooth.id) {
                scoRequestedFor = bluetooth.id
                Log.i(TAG, "headset ${bluetooth.name}: starting SCO")
                devices.connectSco(bluetooth)
            }
            val next = when {
                bluetooth != null && devices.scoConnected -> AudioRoute.HEADSET
                wired != null -> AudioRoute.HEADSET
                else -> AudioRoute.PHONE_MIC
            }
            changed = if (next != route) next else null
            if (changed != null) route = changed
        }
        if (changed != null) {
            Log.i(TAG, "route → $changed")
            onRoute(changed)
            events.audioSession(AudioSessionMsg(AudioSessionKind.ROUTE_CHANGED, changed))
        }
    }

    private fun setInterrupted(on: Boolean) {
        val emit = synchronized(lock) {
            if (!running || interrupted == on) false else { interrupted = on; true }
        }
        if (emit) {
            Log.i(TAG, if (on) "interrupted (audio focus lost)" else "resumed")
            events.audioSession(
                AudioSessionMsg(if (on) AudioSessionKind.INTERRUPTED else AudioSessionKind.RESUMED, route),
            )
        }
    }

    private companion object {
        const val TAG = "AudioRouter"
    }
}

/**
 * Real inputs from AudioManager. SCO: `setCommunicationDevice` on API 31+, `startBluetoothSco` and the
 * SCO state broadcast below.
 */
class AndroidAudioDeviceSource(private val context: Context) : AudioDeviceSource {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var onChange: (() -> Unit)? = null
    @Volatile private var scoUp = false
    private var legacyScoStarted = false

    override val scoConnected: Boolean get() = scoUp

    override fun inputs(): List<InputDevice> =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS).map { InputDevice(it.id, it.type, it.productName.toString()) }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) { onChange?.invoke() }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            if (removedDevices.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }) scoUp = false
            onChange?.invoke()
        }
    }

    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_ERROR)
            Log.i(TAG, "SCO state $state")
            scoUp = state == AudioManager.SCO_AUDIO_STATE_CONNECTED
            if (state == AudioManager.SCO_AUDIO_STATE_CONNECTED) audio.isBluetoothScoOn = true
            onChange?.invoke()
        }
    }

    /** Created only on API 31+: the listener type does not exist on older Android (the Note 9 has 29) */
    private var communicationListener: Any? = null

    @RequiresApi(Build.VERSION_CODES.S)
    private fun communicationListener(): AudioManager.OnCommunicationDeviceChangedListener {
        (communicationListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let { return it }
        val l = AudioManager.OnCommunicationDeviceChangedListener { device ->
            scoUp = device?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            onChange?.invoke()
        }
        communicationListener = l
        return l
    }

    override fun start(onChange: () -> Unit) {
        this.onChange = onChange
        audio.registerAudioDeviceCallback(deviceCallback, main)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.addOnCommunicationDeviceChangedListener(context.mainExecutor, communicationListener())
        } else {
            context.registerReceiver(scoReceiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))
        }
    }

    override fun stop() {
        onChange = null
        audio.unregisterAudioDeviceCallback(deviceCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.removeOnCommunicationDeviceChangedListener(communicationListener())
        } else {
            try { context.unregisterReceiver(scoReceiver) } catch (_: IllegalArgumentException) {}
        }
    }

    override fun connectSco(device: InputDevice) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val target = audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            val ok = target != null && audio.setCommunicationDevice(target)
            Log.i(TAG, "setCommunicationDevice(${target?.productName}) = $ok")
            scoUp = ok
        } else {
            @Suppress("DEPRECATION")
            audio.startBluetoothSco()
            legacyScoStarted = true
            // scoUp follows ACTION_SCO_AUDIO_STATE_UPDATED
        }
    }

    override fun disconnectSco() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audio.clearCommunicationDevice()
        } else if (legacyScoStarted) {
            @Suppress("DEPRECATION")
            audio.stopBluetoothSco()
            audio.isBluetoothScoOn = false
            legacyScoStarted = false
        }
        scoUp = false
    }

    private companion object {
        const val TAG = "AudioDevices"
    }
}
