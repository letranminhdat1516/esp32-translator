package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Review Focus 5: Whisper's known hallucinations on silence and noise never become subtitles */
class HallucinationFilterTest {
    private fun seg(text: String, noSpeech: Float = 0.1f) = WhisperSegment(text, noSpeech)
    private fun filter(vararg s: WhisperSegment) = HallucinationFilter.filter(s.toList())

    @Test fun keepsNormalSpeech() {
        assertEquals("Hôm qua tôi đi làm về muộn.", filter(seg(" Hôm qua tôi đi làm về muộn.")))
        assertEquals("Where is the station? Thank you.", filter(seg(" Where is the station?"), seg(" Thank you.")))
    }

    @Test fun dropsSegmentsThatAreProbablyNotSpeech() {
        assertNull(filter(seg("Thanks.", noSpeech = 0.61f)))
        assertEquals("Hello there.", filter(seg("Hello there.", 0.6f), seg("Bye.", 0.9f)))
    }

    @Test fun dropsTheListedPhrases() {
        assertNull(filter(seg(" Thank you for watching!")))
        assertNull(filter(seg(" Thanks for watching.")))
        assertNull(filter(seg(" Subtitles by the Amara.org community")))
        assertNull(filter(seg(" Cảm ơn các bạn đã theo dõi.")))
        assertNull(filter(seg(" Hãy subscribe cho kênh Ghiền Mì Gõ để không bỏ lỡ những video hấp dẫn")))
        assertNull(filter(seg(" [Music]")))
        assertNull(filter(seg("[MUSIC PLAYING]"), seg("(applause)")))
        assertNull(filter(seg(" ♪ ♪")))
        assertNull(filter(seg("[BLANK_AUDIO]")))
    }

    @Test fun keepsTheSpeechAroundAListedPhrase() {
        assertEquals("Hẹn gặp lại.", filter(seg("Hẹn gặp lại. Cảm ơn các bạn đã theo dõi!")))
        assertEquals("Turn left here.", filter(seg("[Music] Turn left here.")))
    }

    @Test fun dropsAPhraseRepeatedMoreThanTwice() {
        assertNull(filter(seg("Cảm ơn bạn. Cảm ơn bạn. Cảm ơn bạn.")))
        assertNull(filter(seg("I'm going to go I'm going to go I'm going to go")))
        assertNull(filter(seg("Okay."), seg("Okay."), seg("Okay.")))
    }

    @Test fun keepsAPhraseSaidTwiceOrALoneRepeatedWord() {
        assertEquals("Cảm ơn bạn. Cảm ơn bạn.", filter(seg("Cảm ơn bạn. Cảm ơn bạn.")))
        // "Vâng vâng vâng" is ordinary Vietnamese: single words may repeat
        assertEquals("Vâng vâng vâng, tôi hiểu rồi.", filter(seg("Vâng vâng vâng, tôi hiểu rồi.")))
    }

    /** Seen on the Note 9: 3 s of digital silence gave " you" with no_speech_prob 2e-5 */
    @Test fun dropsALoneYou() {
        assertNull(filter(seg(" you")))
        assertNull(filter(seg(" You.")))
        assertEquals("Are you there?", filter(seg("Are you there?")))
    }

    @Test fun emptyIsNull() {
        assertNull(filter())
        assertNull(filter(seg("   ")))
        assertNull(filter(seg(" ...")))
    }
}
