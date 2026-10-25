package vn.cicca.livetranslator.engine

/**
 * Typed engine failures. The pigeon channel turns a [FlutterError] into a Dart `PlatformException`
 * whose `code` is the `EngineError` enum name (controller ruling, Phase 0).
 */
object EngineErrors {
    fun translateFailed(message: String?) = FlutterError("translateFailed", message)
    fun notReady(message: String?) = FlutterError("notReady", message)
    fun downloadFailed(message: String?) = FlutterError("downloadFailed", message)
}

/**
 * The home language code. Vietnamese is always the home side (constraints), and three native paths
 * need it without a pair in hand: the Vietnamese TTS voice in `capabilities()`, the TTS locale and the
 * mine-side recognizer default. A language code, not a locale literal: the region comes from the device.
 */
const val HOME_LANGUAGE = "vi"
