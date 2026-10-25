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

/**
 * The mic: AudioRecord on VOICE_COMMUNICATION (echo cancellation, follows the SCO route), 16 kHz mono
 * PCM16 in 20 ms reads, through [VoiceGate] to [sink]. Emits `gate(open)` on every gate change.
 * The mic is held only between [start] and [stop] (`micOn`).
 */
class MicCapture(
    private val gate: VoiceGate,
    private val events: EngineEventSink,
    private val sink: UtteranceSink,
    /** Session clock: ms since the conversation started */
    private val clock: () -> Long,
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

    @SuppressLint("MissingPermission") // the engine checks RECORD_AUDIO before start
    fun start() {
        if (running) return
        running = true
        val t = Thread({ loop() }, "mic-capture")
        thread = t
        t.start()
    }

    fun stop() {
        running = false
        thread?.join(1_000)
        thread = null
    }

    @SuppressLint("MissingPermission")
    private fun loop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, CHUNK * 2 * 8),
            )
        } catch (e: Exception) {
            fail("AudioRecord: ${e.message}")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            fail("AudioRecord not initialized (permission or mic busy)")
            return
        }
        val chunk = ShortArray(CHUNK)
        var wasOpen = false
        var utteranceStart = 0L
        try {
            record.startRecording()
            Log.i(TAG, "mic on (${record.routedDevice?.productName ?: "default"})")
            var checkSilencedAt = SAMPLE_RATE.toLong() // after 1 s, and every 10 s
            while (running) {
                if (framesRead >= checkSilencedAt) {
                    checkSilencedAt += 10L * SAMPLE_RATE
                    // Android silences a capture it does not allow (background, another app has priority)
                    silenced = record.activeRecordingConfiguration?.isClientSilenced == true
                    if (silenced) Log.w(TAG, "the system is silencing the mic")
                }
                val n = record.read(chunk, 0, chunk.size)
                if (n < 0) {
                    fail("read error $n")
                    break
                }
                if (n == 0) continue
                framesRead += n
                val db = VoiceGate.levelDB(VoiceGate.toFloats(if (n == chunk.size) chunk else chunk.copyOf(n)))
                if (db > windowPeak) windowPeak = db
                if (framesRead >= peakWindowEnd) {
                    peakDB = windowPeak
                    windowPeak = -100f
                    peakWindowEnd += 10L * SAMPLE_RATE
                }
                val now = clock()
                // The gate's events carry its state: audio only while open, then one Ended when it closes
                for (event in gate.process(if (n == chunk.size) chunk else chunk.copyOf(n), SAMPLE_RATE)) {
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
            try { record.stop() } catch (_: IllegalStateException) {}
            record.release()
            if (wasOpen) {
                sink.ended(utteranceStart, clock())
                events.gate(false)
            }
            Log.i(TAG, "mic off after ${framesRead / SAMPLE_RATE} s of audio")
        }
    }

    private fun fail(message: String) {
        lastError = message
        running = false
        Log.e(TAG, message)
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
