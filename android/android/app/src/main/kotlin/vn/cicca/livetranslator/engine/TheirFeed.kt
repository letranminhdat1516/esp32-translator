package vn.cicca.livetranslator.engine

import android.util.Log

/**
 * Board PCM into the their-side (X) recognizer, and whether that recognizer is alive.
 *
 * Contract (NativeVoiceEngine.ts, `feedTheirAudio`): a feed throws `notReady` whenever the their-side
 * recognizer is not running: never started, stopped, or given up after a fatal error ([Life.die], called
 * through [RecognizerRequest.onFatal]); it keeps throwing until the next successful start attaches a new
 * recognizer with a new [Life]. The JS controller reads that rejection as "their recognizer died".
 */
class TheirFeed {
    /** One recognizer's life: alive until [die]; a dead life never comes back (a new start makes a new one) */
    class Life {
        @Volatile var fatal: String? = null
            private set

        val alive: Boolean get() = fatal == null

        fun die(reason: String) {
            if (fatal == null) {
                fatal = reason
                Log.w(TAG, "their recognizer gave up: $reason")
            }
        }
    }

    private class Target(val recognizer: UtteranceRecognizer, val life: Life)

    @Volatile private var target: Target? = null

    fun newLife() = Life()

    /** A started session's their-side recognizer (replaces the previous one) */
    fun attach(recognizer: UtteranceRecognizer, life: Life) {
        target = Target(recognizer, life)
    }

    /** The session stopped */
    fun detach() {
        target = null
    }

    val alive: Boolean get() = target?.life?.alive == true

    /** Feeds the running recognizer; throws `notReady` when there is none or it gave up */
    fun feed(pcm: ShortArray, sampleRate: Int) {
        val t = target ?: throw EngineErrors.notReady("their recognizer is not running (no session)")
        t.life.fatal?.let { throw EngineErrors.notReady("their recognizer gave up: $it") }
        t.recognizer.audio(pcm, sampleRate)
    }

    private companion object {
        const val TAG = "TheirFeed"
    }
}
