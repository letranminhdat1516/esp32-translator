package vn.cicca.livetranslator.engine

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import android.os.SystemClock
import android.util.Log
import kotlin.math.max

/** Receives the gated mic audio of one utterance at a time (the Vietnamese recognizer) */
interface UtteranceSink {
    /** Audio of the current utterance, 16-bit mono at [MicCapture.SAMPLE_RATE] */
    fun audio(pcm: ShortArray)
    /** The gate closed: the utterance that started at [startMs] ended at [endMs] (ms since the session start) */
    fun ended(startMs: Long, endMs: Long)
}

/** A recording mic, already started. Injectable so mic failures can be tested */
interface MicSource {
    val deviceName: String
    /** Fills [buffer]; the number of samples, or a negative AudioRecord error code */
    fun read(buffer: ShortArray): Int
    /** The system delivers silence instead of the mic */
    fun silenced(): Boolean
    fun stop()
}

/** AudioRecord on VOICE_COMMUNICATION, 16 kHz mono PCM16; throws when it cannot record */
@SuppressLint("MissingPermission") // the engine checks RECORD_AUDIO before the mic starts
class AudioRecordSource : MicSource {
    private val record: AudioRecord

    init {
        val minBuffer = AudioRecord.getMinBufferSize(
            MicCapture.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION, MicCapture.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, MicCapture.CHUNK * 2 * 8),
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("AudioRecord not initialized (permission or mic busy)")
        }
        try {
            record.startRecording()
        } catch (e: IllegalStateException) {
            record.release()
            throw e
        }
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            throw IllegalStateException("AudioRecord did not start recording")
        }
    }

    override val deviceName: String get() = record.routedDevice?.productName?.toString() ?: "default"
    override fun read(buffer: ShortArray): Int = record.read(buffer, 0, buffer.size)
    override fun silenced(): Boolean = record.activeRecordingConfiguration?.isClientSilenced == true
    override fun stop() {
        try { record.stop() } catch (_: IllegalStateException) {}
        record.release()
    }
}

/**
 * The mic: 16 kHz mono PCM16 in 20 ms reads (AudioRecord on VOICE_COMMUNICATION: echo cancellation, follows
 * the SCO route), through [VoiceGate] to [sink]. Emits `gate(open)` on every gate change.
 * The mic is held only between [start] and [stop] (`micOn`).
 *
 * A mic that cannot be opened makes [start] throw `notReady`; a mic that stops delivering (read error)
 * ends the capture. Both emit `audioSession(interrupted)`, so Dart knows the mic is gone.
 */
class MicCapture(
    private val gate: VoiceGate,
    private val events: EngineEventSink,
    private val sink: UtteranceSink,
    /** Session clock: ms since the conversation started */
    private val clock: () -> Long,
    private val open: () -> MicSource = { AudioRecordSource() },
) {
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile var framesRead = 0L
        private set
    @Volatile var lastError: String? = null
        private set
    /** The system delivers silence instead of the mic (checked every 10 s) */
    @Volatile var silenced = false
        private set
    /** Loudest 20 ms frame of the last 10 s of audio (dB), for the heartbeat */
    @Volatile var peakDB = -100f
        private set
    private var windowPeak = -100f
    private var peakWindowEnd = 10L * SAMPLE_RATE

    val isRunning: Boolean get() = running

    /** Opens the mic now (throws `notReady` when it cannot) and reads it on a thread */
    @Synchronized
    fun start() {
        if (running) return
        val source = try {
            open()
        } catch (e: Exception) {
            fail("mic could not start: ${e.message}")
            throw EngineErrors.notReady("microphone unavailable: ${e.message}")
        }
        lastError = null
        running = true
        val t = Thread({ loop(source) }, "mic-capture")
        thread = t
        t.start()
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(1_000)
        thread = null
    }

    private fun loop(source: MicSource) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val chunk = ShortArray(CHUNK)
        var wasOpen = false
        var utteranceStart = 0L
        try {
            Log.i(TAG, "mic on (${source.deviceName})")
            var checkSilencedAt = SAMPLE_RATE.toLong() // after 1 s, and every 10 s
            while (running) {
                if (framesRead >= checkSilencedAt) {
                    checkSilencedAt += 10L * SAMPLE_RATE
                    // Android silences a capture it does not allow (background, another app has priority)
                    silenced = source.silenced()
                    if (silenced) Log.w(TAG, "the system is silencing the mic")
                }
                val n = source.read(chunk)
                if (n < 0) {
                    fail("read error $n")
                    break
                }
                if (n == 0) continue
                framesRead += n
                val samples = if (n == chunk.size) chunk else chunk.copyOf(n)
                val db = VoiceGate.levelDB(VoiceGate.toFloats(samples))
                if (db > windowPeak) windowPeak = db
                if (framesRead >= peakWindowEnd) {
                    peakDB = windowPeak
                    windowPeak = -100f
                    peakWindowEnd += 10L * SAMPLE_RATE
                }
                val now = clock()
                // The gate's events carry its state: audio only while open, then one Ended when it closes
                for (event in gate.process(samples, SAMPLE_RATE)) {
                    when (event) {
                        is VoiceGate.Event.Audio -> {
                            if (!wasOpen) {
                                wasOpen = true
                                // Pre-roll included: the utterance began this much audio before now
                                utteranceStart = max(0, now - event.samples.size * 1000L / SAMPLE_RATE)
                                events.gate(true)
                            }
                            sink.audio(VoiceGate.toPcm16(event.samples))
                        }
                        VoiceGate.Event.Ended -> {
                            wasOpen = false
                            events.gate(false)
                            sink.ended(utteranceStart, now)
                        }
                    }
                }
            }
        } finally {
            source.stop()
            if (wasOpen) {
                sink.ended(utteranceStart, clock())
                events.gate(false)
            }
            Log.i(TAG, "mic off after ${framesRead / SAMPLE_RATE} s of audio")
        }
    }

    /** Records the failure, stops, and tells Dart the mic is gone */
    private fun fail(message: String) {
        lastError = message
        running = false
        Log.e(TAG, message)
        events.audioSession(AudioSessionMsg(AudioSessionKind.INTERRUPTED, null))
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        /** 20 ms */
        const val CHUNK = SAMPLE_RATE / 50
        private const val TAG = "MicCapture"
        /** Session clock helper */
        fun since(startElapsed: Long) = SystemClock.elapsedRealtime() - startElapsed
    }
}
