package vn.cicca.livetranslator.engine

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList

/**
 * E1 / Review Focus 4 on the Note 9. Audio focus and the communication mode are real (AudioManager);
 * the input devices and the SCO link come from a fake source, so no headset is needed.
 */
@RunWith(AndroidJUnit4::class)
class AudioRouterTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val audio get() = context.getSystemService(AudioManager::class.java)

    /** A Bluetooth headset that can be plugged in and out; SCO comes up when asked unless [scoWorks] is false */
    private class FakeDevices : AudioDeviceSource {
        val devices = CopyOnWriteArrayList<InputDevice>()
        var scoWorks = true
        override var scoConnected = false
        var scoRequests = 0
        private var onChange: (() -> Unit)? = null

        override fun inputs(): List<InputDevice> = devices.toList()
        override fun start(onChange: () -> Unit) { this.onChange = onChange }
        override fun stop() { onChange = null }
        override fun connectSco(device: InputDevice) {
            scoRequests++
            if (scoWorks) { scoConnected = true; onChange?.invoke() }
        }
        override fun disconnectSco() { scoConnected = false }

        fun plug(d: InputDevice) { devices += d; onChange?.invoke() }
        fun unplug(d: InputDevice) {
            devices -= d
            scoConnected = false
            onChange?.invoke()
        }
    }

    private val builtIn = InputDevice(1, AudioDeviceInfo.TYPE_BUILTIN_MIC, "phone")
    private val headset = InputDevice(7, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, "Earbuds")
    private val routes = CopyOnWriteArrayList<AudioSessionMsg>()
    private val sink = object : EngineEventSink {
        override fun audioSession(msg: AudioSessionMsg) { routes += msg }
    }
    private lateinit var router: AudioRouter

    @After fun tearDown() {
        if (::router.isInitialized) router.stop()
    }

    private fun routeChanged(route: AudioRoute) = AudioSessionMsg(AudioSessionKind.ROUTE_CHANGED, route)

    @Test fun scoHeadsetIsUsedAndItsLossFallsBackToThePhoneMic() {
        val devices = FakeDevices().apply { this.devices += builtIn; this.devices += headset }
        router = AudioRouter(context, sink, devices)
        router.start()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audio.mode)
        assertEquals(AudioRoute.HEADSET, router.route)
        assertEquals(listOf(routeChanged(AudioRoute.HEADSET)), routes.toList())

        // Review Focus 4: the headset disconnects mid-conversation
        devices.unplug(headset)
        assertEquals(AudioRoute.PHONE_MIC, router.route)
        assertEquals(listOf(routeChanged(AudioRoute.HEADSET), routeChanged(AudioRoute.PHONE_MIC)), routes.toList())

        // …and comes back: SCO is asked for again
        devices.plug(headset)
        assertEquals(AudioRoute.HEADSET, router.route)
        assertEquals(2, devices.scoRequests)
        assertEquals(routeChanged(AudioRoute.HEADSET), routes.last())
    }

    @Test fun noHeadsetMeansPhoneMic() {
        val devices = FakeDevices().apply { this.devices += builtIn }
        router = AudioRouter(context, sink, devices)
        router.start()
        assertEquals(AudioRoute.PHONE_MIC, router.route)
        assertEquals(listOf(routeChanged(AudioRoute.PHONE_MIC)), routes.toList())
    }

    @Test fun scoThatNeverConnectsStaysOnThePhoneMic() {
        val devices = FakeDevices().apply { this.devices += builtIn; this.devices += headset; scoWorks = false }
        router = AudioRouter(context, sink, devices)
        router.start()
        assertEquals(1, devices.scoRequests)
        assertEquals(AudioRoute.PHONE_MIC, router.route)
    }

    @Test fun routeListenerSeesEveryChange() {
        val devices = FakeDevices().apply { this.devices += builtIn; this.devices += headset }
        val seen = mutableListOf<AudioRoute>()
        router = AudioRouter(context, sink, devices, onRoute = { seen += it })
        router.start()
        devices.unplug(headset)
        assertEquals(listOf(AudioRoute.HEADSET, AudioRoute.PHONE_MIC), seen)
    }

    @Test fun stopRestoresTheNormalMode() {
        val devices = FakeDevices().apply { this.devices += builtIn }
        router = AudioRouter(context, sink, devices)
        router.start()
        router.stop()
        assertEquals(AudioManager.MODE_NORMAL, audio.mode)
        assertTrue(!devices.scoConnected)
    }

    /** The real device source on this phone: lists the built-in mic, so start() routes to the phone mic */
    @Test fun realDeviceSourceWithoutAHeadset() {
        val real = AndroidAudioDeviceSource(context)
        val inputs = real.inputs()
        assertTrue(inputs.toString(), inputs.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC })
        if (inputs.none { it.isHeadset }) {
            router = AudioRouter(context, sink, real)
            router.start()
            assertEquals(AudioRoute.PHONE_MIC, router.route)
        }
    }
}
