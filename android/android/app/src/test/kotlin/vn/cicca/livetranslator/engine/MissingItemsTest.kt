package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class MissingItemsTest {
    private val translation = MissingMsg(MissingKind.TRANSLATION, "ja", from = "vi", to = "ja")

    @Test fun noVietnameseVoiceAddsTtsVoice() {
        val items = MissingItems.compute(emptyList(), emptyList(), vietnameseVoice = false, home = HOME_LANGUAGE)
        assertEquals(listOf(MissingMsg(MissingKind.TTS_VOICE, HOME_LANGUAGE)), items)
    }

    @Test fun theVoiceItemNamesTheGivenHome() {
        val items = MissingItems.compute(emptyList(), emptyList(), vietnameseVoice = false, home = "ja")
        assertEquals(listOf(MissingMsg(MissingKind.TTS_VOICE, "ja")), items)
    }

    @Test fun everythingPresentIsEmpty() {
        assertEquals(emptyList<MissingMsg>(), MissingItems.compute(emptyList(), emptyList(), vietnameseVoice = true, home = HOME_LANGUAGE))
    }

    @Test fun speechModelsThenTranslationThenVoice() {
        val items = MissingItems.compute(listOf(translation), listOf("vi", "ja"), vietnameseVoice = false, home = HOME_LANGUAGE)
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
