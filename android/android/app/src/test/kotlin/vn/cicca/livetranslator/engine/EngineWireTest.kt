package vn.cicca.livetranslator.engine

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

/**
 * The TurboModule wire (android/src/engine/NativeVoiceEngine.ts): JS numbers arrive as Double (Int32 too),
 * enums cross as their TS names, board PCM as base64 of 16-bit little-endian samples.
 */
class EngineWireTest {
    @Test fun pairTakesTheGenerationAsADouble() {
        val pair = EngineWire.pair(mapOf("home" to HOME_LANGUAGE, "other" to "en", "generation" to 7.0))
        assertEquals(PairMsg(HOME_LANGUAGE, "en", 7), pair)
    }

    @Test fun aNonIntegralOrMissingInt32IsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            EngineWire.pair(mapOf("home" to HOME_LANGUAGE, "other" to "en", "generation" to 1.5))
        }
        assertThrows(IllegalArgumentException::class.java) {
            EngineWire.pair(mapOf("home" to HOME_LANGUAGE, "other" to "en"))
        }
        assertThrows(IllegalArgumentException::class.java) { EngineWire.int32(3e10) }
        assertEquals(-2L, EngineWire.int32(-2.0))
    }

    @Test fun missingRoundTripsWithItsTsKindNames() {
        val items = listOf(
            MissingMsg(MissingKind.SPEECH_MODEL, "en"),
            MissingMsg(MissingKind.TRANSLATION, "en", from = HOME_LANGUAGE, to = "en"),
            MissingMsg(MissingKind.TTS_VOICE, HOME_LANGUAGE),
        )
        val wire = items.map(EngineWire::missing)
        assertEquals(listOf("speechModel", "translation", "ttsVoice"), wire.map { it["kind"] })
        assertEquals(mapOf("kind" to "translation", "language" to "en", "from" to HOME_LANGUAGE, "to" to "en"), wire[1])
        assertEquals(items, wire.map(EngineWire::missingItem))
    }

    @Test fun anUnknownMissingKindIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            EngineWire.missingItem(mapOf("kind" to "SPEECH_MODEL", "language" to "en"))
        }
    }

    @Test fun capabilitiesBecomePlainMapsAndLists() {
        val caps = CapabilitiesMsg(
            recognizers = listOf(RecognizerEntryMsg(HOME_LANGUAGE, listOf(Kinds.WHISPER, Kinds.OS_ONLINE))),
            translatable = listOf("en", HOME_LANGUAGE),
            vietnameseVoice = true,
        )
        assertEquals(
            mapOf(
                "recognizers" to listOf(mapOf("language" to HOME_LANGUAGE, "kinds" to listOf(Kinds.WHISPER, Kinds.OS_ONLINE))),
                "translatable" to listOf("en", HOME_LANGUAGE),
                "vietnameseVoice" to true,
            ),
            EngineWire.capabilities(caps),
        )
    }

    @Test fun eventsCarryNumbersAsDoublesAndEnumsByName() {
        assertEquals(
            mapOf("kind" to "finalText", "text" to "xin chào", "startMs" to 100.0, "endMs" to 900.0),
            EngineWire.mine(MineMsg(MineKind.FINAL_TEXT, "xin chào", 100, 900)),
        )
        assertEquals(
            mapOf("text" to "hello", "confidence" to null, "generation" to 3.0),
            EngineWire.theirs(TheirsMsg("hello", null, 3)),
        )
        assertEquals(
            mapOf("kind" to "routeChanged", "route" to "phoneMic"),
            EngineWire.audioSession(AudioSessionMsg(AudioSessionKind.ROUTE_CHANGED, AudioRoute.PHONE_MIC)),
        )
        assertEquals(
            mapOf("kind" to "interrupted", "route" to null),
            EngineWire.audioSession(AudioSessionMsg(AudioSessionKind.INTERRUPTED)),
        )
        val item = MissingMsg(MissingKind.SPEECH_MODEL, "en")
        assertEquals(
            mapOf("item" to EngineWire.missing(item), "progress" to 0.5, "done" to false, "error" to null),
            EngineWire.download(DownloadMsg(item, 0.5, false)),
        )
    }

    @Test fun base64PcmDecodesToLittleEndianSamples() {
        val samples = shortArrayOf(0, 1, -1, Short.MAX_VALUE, Short.MIN_VALUE, 0x1234)
        val bytes = ByteArray(samples.size * 2)
        samples.forEachIndexed { i, s ->
            bytes[2 * i] = (s.toInt() and 0xFF).toByte()
            bytes[2 * i + 1] = (s.toInt() shr 8).toByte()
        }
        assertArrayEquals(samples, EngineWire.pcm16(Base64.getEncoder().encodeToString(bytes)))
        assertArrayEquals(ShortArray(0), EngineWire.pcm16(""))
    }

    @Test fun aRejectionCodeIsTheEngineErrorNameOrTheCallsFallback() {
        assertEquals("translateFailed", EngineWire.errorCode(EngineErrors.translateFailed("x"), "notReady"))
        assertEquals("downloadFailed", EngineWire.errorCode(IllegalStateException("x"), "downloadFailed"))
        assertEquals("notReady", EngineWire.errorCode(IllegalArgumentException("bad pair"), "notReady"))
    }
}
