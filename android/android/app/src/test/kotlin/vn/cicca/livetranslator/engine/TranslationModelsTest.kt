package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslationModelsTest {
    // Language codes as the catalog passes them; ML Kit uses the same tags for these
    private val supported = setOf("en", "vi", "ja", "fr")
    private val models = TranslationModels(supported = { it.takeIf { c -> c in supported } })

    @Test fun nothingMissingWhenBothModelsArePresent() {
        assertTrue(models.missing("vi", "ja", downloaded = setOf("vi", "ja")).isEmpty())
    }

    @Test fun englishIsBuiltIn() {
        assertTrue(models.missing("vi", "en", downloaded = setOf("vi")).isEmpty())
        assertEquals(listOf("vi"), models.needed("vi", "en"))
    }

    @Test fun oneItemPerPairWhenAnyModelIsMissing() {
        val missing = models.missing("vi", "ja", downloaded = setOf("vi"))
        assertEquals(listOf(MissingMsg(MissingKind.TRANSLATION, "ja", from = "vi", to = "ja")), missing)
        assertEquals(listOf("vi", "ja"), models.needed("vi", "ja"))
        assertEquals(listOf("ja"), models.toDownload("vi", "ja", downloaded = setOf("vi")))
    }

    @Test fun unsupportedLanguageIsReportedAsMissingAndCannotBeDownloaded() {
        val missing = models.missing("vi", "xx", downloaded = setOf("vi"))
        assertEquals(1, missing.size)
        try {
            models.toDownload("vi", "xx", downloaded = setOf("vi"))
            throw AssertionError("expected downloadFailed")
        } catch (e: EngineException) {
            assertEquals("downloadFailed", e.code)
        }
    }
}
