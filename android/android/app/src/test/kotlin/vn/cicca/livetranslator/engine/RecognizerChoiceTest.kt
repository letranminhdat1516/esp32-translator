package vn.cicca.livetranslator.engine

import org.junit.Assert.assertEquals
import org.junit.Test

class RecognizerChoiceTest {
    private fun phone(api: Int, onDevice: Set<String> = emptySet(), online: Boolean = true, whisper: Boolean = true) =
        RecognizerChoice(api = api, onDeviceLanguages = onDevice, onlineAvailable = online, whisperAvailable = whisper)

    @Test fun note9OffersWhisperForBothAndOnlineOnlyForTheMicSide() {
        val note9 = phone(api = 29)
        assertEquals(listOf(Kinds.WHISPER, Kinds.OS_ONLINE), note9.kinds(HOME_LANGUAGE, fromMic = true))
        // The other language comes from the board as PCM: OS recognizers cannot take it before Android 13
        assertEquals(listOf(Kinds.WHISPER), note9.kinds("en", fromMic = false))
    }

    @Test fun android13OffersOnDeviceFirstForBothSides() {
        val p = phone(api = 34, onDevice = setOf(HOME_LANGUAGE, "en"))
        assertEquals(listOf(Kinds.OS_ON_DEVICE, Kinds.WHISPER, Kinds.OS_ONLINE), p.kinds("en", fromMic = false))
        assertEquals(listOf(Kinds.OS_ON_DEVICE, Kinds.WHISPER, Kinds.OS_ONLINE), p.kinds(HOME_LANGUAGE, fromMic = true))
        assertEquals(listOf(Kinds.WHISPER, Kinds.OS_ONLINE), p.kinds("ja", fromMic = false))
    }

    @Test fun android12OnDeviceIsMicOnly() {
        val p = phone(api = 31, onDevice = setOf(HOME_LANGUAGE, "en"))
        assertEquals(listOf(Kinds.OS_ON_DEVICE, Kinds.WHISPER, Kinds.OS_ONLINE), p.kinds(HOME_LANGUAGE, fromMic = true))
        assertEquals(listOf(Kinds.WHISPER), p.kinds("en", fromMic = false))
    }

    @Test fun noWhisperLibraryNoOnlineService() {
        assertEquals(emptyList<String>(), phone(api = 29, online = false, whisper = false).kinds("en", fromMic = false))
    }

    @Test fun whisperOnlyForItsLanguages() {
        assertEquals(emptyList<String>(), phone(api = 29).kinds("xx", fromMic = false))
    }

    @Test fun mineSidePrefersOnDeviceThenWhisperAndUsesOnlineOnlyWhenAskedFor() {
        assertEquals(Kinds.OS_ON_DEVICE, phone(api = 31, onDevice = setOf(HOME_LANGUAGE)).mine(HOME_LANGUAGE, Kinds.WHISPER))
        assertEquals(Kinds.WHISPER, phone(api = 29).mine(HOME_LANGUAGE, Kinds.WHISPER))
        // Consent for online is held in Dart and shown by asking for osOnline; still, Whisper (offline) wins
        assertEquals(Kinds.WHISPER, phone(api = 29).mine(HOME_LANGUAGE, Kinds.OS_ONLINE))
        // Without Whisper, online is used only when Dart asked for it
        assertEquals(Kinds.OS_ONLINE, phone(api = 29, whisper = false).mine(HOME_LANGUAGE, Kinds.OS_ONLINE))
        assertEquals(Kinds.WHISPER, phone(api = 29, whisper = false).mine(HOME_LANGUAGE, Kinds.WHISPER))
    }

    @Test fun theMicSideIsWhateverTheCallerSaysNotAFixedLanguage() {
        val note9 = phone(api = 29)
        // The mic side may take the OS recognizer below Android 13, whatever the home language is
        assertEquals(listOf(Kinds.WHISPER, Kinds.OS_ONLINE), note9.kinds("ja", fromMic = true))
        assertEquals(listOf(Kinds.WHISPER), note9.kinds(HOME_LANGUAGE, fromMic = false))
    }

    @Test fun mineSideUsesTheGivenHomeForOnDevice() {
        val p = phone(api = 31, onDevice = setOf("ja"))
        assertEquals(Kinds.OS_ON_DEVICE, p.mine("ja", Kinds.WHISPER))
        assertEquals(Kinds.WHISPER, p.mine(HOME_LANGUAGE, Kinds.WHISPER))
    }

    @Test fun fedAudioNeedsAndroid13ForOsRecognizers() {
        assertEquals(false, phone(api = 29).canFeed(Kinds.OS_ONLINE))
        assertEquals(false, phone(api = 32).canFeed(Kinds.OS_ON_DEVICE))
        assertEquals(true, phone(api = 33).canFeed(Kinds.OS_ONLINE))
        assertEquals(true, phone(api = 29).canFeed(Kinds.WHISPER))
    }
}
