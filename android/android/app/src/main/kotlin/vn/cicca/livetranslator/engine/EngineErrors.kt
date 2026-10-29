package vn.cicca.livetranslator.engine

/**
 * Typed engine failures. VoiceEngineModule rejects the JS promise with [EngineException.code], the
 * `EngineErrorCode` name the TS adapter maps back to an `EngineError` (controller ruling, Phase 0).
 */
object EngineErrors {
    fun translateFailed(message: String?) = EngineException("translateFailed", message)
    fun notReady(message: String?) = EngineException("notReady", message)
    fun downloadFailed(message: String?) = EngineException("downloadFailed", message)
}
