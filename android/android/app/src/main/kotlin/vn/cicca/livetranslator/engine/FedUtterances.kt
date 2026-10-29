package vn.cicca.livetranslator.engine

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Calls [onPause] once when audio stopped arriving for [pauseMs] (the board stops streaming in silence, so
 * a pause ends its utterance, as the Swift app's phrase-end watcher). [touch] on every audio chunk.
 */
class PauseWatcher(private val pauseMs: Long, private val onPause: () -> Unit) {
    private val timer: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { Thread(it, "board-pause").apply { isDaemon = true } }
    @Volatile private var lastAudio = 0L
    @Volatile private var pending = false

    init {
        val period = (pauseMs / 2).coerceIn(10, 150)
        timer.scheduleWithFixedDelay({ check() }, period, period, TimeUnit.MILLISECONDS)
    }

    fun touch() {
        lastAudio = System.nanoTime()
        pending = true
    }

    private fun check() {
        if (pending && (System.nanoTime() - lastAudio) / 1_000_000 >= pauseMs) {
            pending = false
            onPause()
        }
    }

    fun close() {
        timer.shutdownNow()
    }
}

/**
 * Feeds a recognizer that reads one audio stream per utterance (Android's SpeechRecognizer with
 * EXTRA_AUDIO_SOURCE, API 33+). Pure state machine, unit-tested with a fake [Session]:
 * - idle → the first audio opens a stream ([Session.begin], a startListening with a new pipe);
 * - [end] (or a board pause of [pauseMs]) closes it; the recognizer then finalizes;
 * - [finished] (its onResults or onError) makes it idle again, so the next utterance opens a new stream;
 *   also when it comes before [end] (mid-stream error, self-endpointing): the open stream is dropped.
 * Audio that arrives while the recognizer is still finalizing is kept for the next utterance.
 *
 * [Session] and [Stream] implementations must not call [finished] from inside [Session.begin] or
 * [Stream.close] on the same thread (the real recognizer answers later, on the main thread).
 */
class FedUtterances(private val session: Session, pauseMs: Long = 250) {
    interface Session {
        /** Starts recognizing a new stream of 16-bit mono PCM at [sampleRate] */
        fun begin(sampleRate: Int): Stream
    }

    interface Stream {
        fun write(pcm: ShortArray)
        /** End of input: the recognizer finalizes and reports through [finished] */
        fun close()
    }

    private val lock = Any()
    private var stream: Stream? = null
    private var finishing = false
    /** Audio of the next utterance received while the last one was finishing, and its end if it came too */
    private val queued = ArrayList<ShortArray>()
    private var queuedRate = 0
    private var queuedEnd = false
    private var closed = false
    private val pause = PauseWatcher(pauseMs) { end() }

    fun audio(pcm: ShortArray, sampleRate: Int) {
        synchronized(lock) {
            if (closed) return
            pause.touch()
            if (finishing) {
                queued += pcm
                queuedRate = sampleRate
                return
            }
            val s = stream ?: session.begin(sampleRate).also { stream = it }
            s.write(pcm)
        }
    }

    /** The utterance ended (board pause, or the engine says so) */
    fun end() {
        synchronized(lock) {
            if (closed) return
            if (finishing) {
                if (queued.isNotEmpty()) queuedEnd = true
                return
            }
            val s = stream ?: return
            stream = null
            finishing = true
            s.close()
        }
    }

    /**
     * The recognizer answered (result or error) for the stream it was reading. It may answer before [end]:
     * an error mid-speech (network, busy) or endpointing on its own. That stream is then dead (nobody reads
     * the pipe and no other callback comes): close and drop it, so the next audio opens a fresh utterance.
     */
    fun finished() {
        synchronized(lock) {
            if (!finishing) {
                stream?.close()
                stream = null
                return
            }
            finishing = false
            if (closed || queued.isEmpty()) return
            val s = session.begin(queuedRate).also { stream = it }
            queued.forEach { s.write(it) }
            queued.clear()
            if (queuedEnd) {
                queuedEnd = false
                stream = null
                finishing = true
                s.close()
            }
        }
    }

    fun close() {
        pause.close()
        synchronized(lock) {
            closed = true
            queued.clear()
            stream?.close()
            stream = null
        }
    }
}
