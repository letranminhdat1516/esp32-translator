package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class MissingItemsTest {
    private val translation = MissingMsg(MissingKind.TRANSLATION, "ja", from = "vi", to = "ja")

    @Test fun noVietnameseVoiceAddsTtsVoice() {
        val items = MissingItems.compute(emptyList(), emptyList(), vietnameseVoice = false)
        assertEquals(listOf(MissingMsg(MissingKind.TTS_VOICE, HOME_LANGUAGE)), items)
    }

    @Test fun everythingPresentIsEmpty() {
        assertEquals(emptyList<MissingMsg>(), MissingItems.compute(emptyList(), emptyList(), vietnameseVoice = true))
    }

    @Test fun speechModelsThenTranslationThenVoice() {
        val items = MissingItems.compute(listOf(translation), listOf("vi", "ja"), vietnameseVoice = false)
        assertEquals(
            listOf(
                MissingMsg(MissingKind.SPEECH_MODEL, "vi"),
                MissingMsg(MissingKind.SPEECH_MODEL, "ja"),
                translation,
                MissingMsg(MissingKind.TTS_VOICE, HOME_LANGUAGE),
            ),
            items,
        )
    }
}
