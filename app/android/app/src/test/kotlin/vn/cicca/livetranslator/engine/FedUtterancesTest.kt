package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Fix round 1, finding 3: the fed-audio OS recognizer (API 33+) reads one stream per utterance. A fake
 * recognizer session stands in for SpeechRecognizer: it "recognizes" a stream when it is closed, as the
 * real one finalizes at end of input, and reports the result (or an error) back.
 */
class FedUtterancesTest {
    /** Each begin() is one startListening with a new pipe; closing the stream yields a result */
    private class FakeRecognizer(private val failFirst: Boolean = false) : FedUtterances.Session {
        lateinit var utterances: FedUtterances
        val results = CopyOnWriteArrayList<String>()
        var begins = 0
        override fun begin(sampleRate: Int): FedUtterances.Stream {
            begins++
            val n = begins
            return object : FedUtterances.Stream {
                var samples = 0
                override fun write(pcm: ShortArray) { samples += pcm.size }
                override fun close() {
                    // The recognizer answers asynchronously, after end of input
                    Thread {
                        Thread.sleep(20)
                        if (failFirst && n == 1) utterances.finished() // onError
                        else { results += "utterance $n: $samples samples"; utterances.finished() } // onResults
                    }.start()
                }
            }
        }
    }

    /**
     * A recognizer that answers on its own while still being fed: after [after] chunks of its first stream it
     * reports an error ([error]) or endpoints and reports a result. Later streams answer only when closed.
     */
    private class MidStreamRecognizer(private val after: Int, private val error: Boolean) : FedUtterances.Session {
        lateinit var utterances: FedUtterances
        val results = CopyOnWriteArrayList<String>()
        val writesAfterAnswer = CopyOnWriteArrayList<Int>()
        var begins = 0
        override fun begin(sampleRate: Int): FedUtterances.Stream {
            begins++
            val n = begins
            return object : FedUtterances.Stream {
                var samples = 0
                var chunks = 0
                @Volatile var answered = false
                override fun write(pcm: ShortArray) {
                    if (answered) { writesAfterAnswer += n; return } // a dead pipe: nobody reads it
                    samples += pcm.size
                    chunks++
                    if (n == 1 && chunks == after) {
                        answered = true
                        val s = samples
                        Thread {
                            Thread.sleep(10)
                            if (!error) results += "utterance $n: $s samples"
                            utterances.finished()
                        }.start()
                    }
                }
                override fun close() {
                    if (answered) return // already answered: a closed dead stream never calls back
                    answered = true
                    val s = samples
                    Thread { Thread.sleep(10); results += "utterance $n: $s samples"; utterances.finished() }.start()
                }
            }
        }
    }

    private fun midStream(after: Int, error: Boolean) =
        MidStreamRecognizer(after, error).let { it to FedUtterances(it, 100).also { u -> it.utterances = u } }

    @Test fun anErrorWhileStreamingIsFollowedByAFreshUtterance() {
        val (fake, u) = midStream(after = 3, error = true)
        repeat(3) { u.audio(ShortArray(320), 16_000) } // the error comes after the 3rd chunk
        Thread.sleep(100)
        repeat(4) { u.audio(ShortArray(320), 16_000) } // more speech, then the utterance ends
        u.end()
        waitFor(1_500) { fake.results.size == 1 }
        assertEquals(listOf("utterance 2: 1280 samples"), fake.results.toList())
        assertEquals(2, fake.begins)
        assertTrue("nothing written into the dead pipe", fake.writesAfterAnswer.isEmpty())
        u.close()
    }

    @Test fun selfEndpointingIsFollowedByAFreshUtterance() {
        val (fake, u) = midStream(after = 5, error = false)
        repeat(5) { u.audio(ShortArray(320), 16_000) } // the recognizer endpoints and answers by itself
        Thread.sleep(100)
        repeat(2) { u.audio(ShortArray(320), 16_000) }
        u.end()
        waitFor(1_500) { fake.results.size == 2 }
        assertEquals(listOf("utterance 1: 1600 samples", "utterance 2: 640 samples"), fake.results.toList())
        assertTrue("nothing written into the dead pipe", fake.writesAfterAnswer.isEmpty())
        u.close()
    }

    private fun fed(fake: FakeRecognizer, pauseMs: Long = 100) =
        FedUtterances(fake, pauseMs).also { fake.utterances = it }

    private fun waitFor(ms: Long, condition: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (!condition() && System.currentTimeMillis() < end) Thread.sleep(10)
    }

    @Test fun twoUtterancesInARowBothProduceResults() {
        val fake = FakeRecognizer()
        val u = fed(fake)
        repeat(10) { u.audio(ShortArray(320), 16_000) }
        u.end()
        waitFor(1_000) { fake.results.size == 1 }
        repeat(5) { u.audio(ShortArray(320), 16_000) }
        u.end()
        waitFor(1_000) { fake.results.size == 2 }
        assertEquals(listOf("utterance 1: 3200 samples", "utterance 2: 1600 samples"), fake.results.toList())
        assertEquals(2, fake.begins)
        u.close()
    }

    @Test fun aBoardPauseEndsTheUtterance() {
        val fake = FakeRecognizer()
        val u = fed(fake, pauseMs = 100)
        repeat(10) { u.audio(ShortArray(320), 16_000) }
        // No end() call: the board stops streaming and the pause ends the utterance
        waitFor(1_500) { fake.results.size == 1 }
        repeat(3) { u.audio(ShortArray(320), 16_000) }
        waitFor(1_500) { fake.results.size == 2 }
        assertEquals(listOf("utterance 1: 3200 samples", "utterance 2: 960 samples"), fake.results.toList())
        u.close()
    }

    @Test fun audioArrivingWhileTheLastUtteranceFinishesGoesToTheNextOne() {
        val fake = FakeRecognizer()
        val u = fed(fake)
        repeat(4) { u.audio(ShortArray(320), 16_000) }
        u.end()
        // The recognizer is still finalizing: this audio must not be lost or sent to a busy recognizer
        repeat(2) { u.audio(ShortArray(320), 16_000) }
        assertEquals(1, fake.begins)
        u.end()
        waitFor(1_500) { fake.results.size == 2 }
        assertEquals(listOf("utterance 1: 1280 samples", "utterance 2: 640 samples"), fake.results.toList())
        u.close()
    }

    @Test fun anErrorDoesNotLeaveItDeaf() {
        val fake = FakeRecognizer(failFirst = true)
        val u = fed(fake)
        repeat(4) { u.audio(ShortArray(320), 16_000) }
        u.end()
        waitFor(500) { fake.begins == 1 }
        Thread.sleep(100)
        repeat(4) { u.audio(ShortArray(320), 16_000) }
        u.end()
        waitFor(1_500) { fake.results.size == 1 }
        assertTrue(fake.results.toString(), fake.results.single().startsWith("utterance 2"))
        u.close()
    }
}
