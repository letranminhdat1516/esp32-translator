package vn.cicca.livetranslator.engine

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64

/**
 * The TurboModule wire of android/src/engine/NativeVoiceEngine.ts, as plain Kotlin maps and lists (no React
 * Native types, so it runs under JUnit). [VoiceEngineModule] converts these to and from ReadableMap.
 * - JS numbers arrive as Double, `Int32` ones too ([int32]); numbers leave as Double.
 * - Enums cross as their TS names ([MissingKind.wire] …).
 * - Board PCM crosses as base64 of 16-bit little-endian mono samples ([pcm16]).
 * - A rejection's code is an `EngineErrorCode` name ([errorCode]).
 * Malformed input throws [IllegalArgumentException].
 */
object EngineWire {
    /** A JS `Int32` (a Double on the Java side) as a Long */
    fun int32(value: Double): Long {
        require(value == Math.rint(value) && value >= Int.MIN_VALUE && value <= Int.MAX_VALUE) {
            "not an Int32: $value"
        }
        return value.toLong()
    }

    private fun Map<String, Any?>.string(key: String): String =
        this[key] as? String ?: throw IllegalArgumentException("$key: expected a string, got ${this[key]}")

    private fun Map<String, Any?>.optString(key: String): String? = this[key] as? String

    private fun Map<String, Any?>.int32(key: String): Long =
        int32((this[key] as? Number ?: throw IllegalArgumentException("$key: expected a number")).toDouble())

    fun pair(map: Map<String, Any?>) = PairMsg(map.string("home"), map.string("other"), map.int32("generation"))

    fun missingItem(map: Map<String, Any?>): MissingMsg {
        val kind = map.string("kind")
        return MissingMsg(
            kind = MissingKind.ofWire(kind) ?: throw IllegalArgumentException("unknown MissingKind \"$kind\""),
            language = map.string("language"),
            from = map.optString("from"),
            to = map.optString("to"),
        )
    }

    fun missing(m: MissingMsg): Map<String, Any?> =
        mapOf("kind" to m.kind.wire, "language" to m.language, "from" to m.from, "to" to m.to)

    fun capabilities(c: CapabilitiesMsg): Map<String, Any?> = mapOf(
        "recognizers" to c.recognizers.map { mapOf("language" to it.language, "kinds" to it.kinds) },
        "translatable" to c.translatable,
        "vietnameseVoice" to c.vietnameseVoice,
    )

    fun mine(m: MineMsg): Map<String, Any?> =
        mapOf("kind" to m.kind.wire, "text" to m.text, "startMs" to m.startMs.toDouble(), "endMs" to m.endMs.toDouble())

    fun theirs(m: TheirsMsg): Map<String, Any?> =
        mapOf("text" to m.text, "confidence" to m.confidence, "generation" to m.generation.toDouble())

    fun audioSession(m: AudioSessionMsg): Map<String, Any?> = mapOf("kind" to m.kind.wire, "route" to m.route?.wire)

    fun download(m: DownloadMsg): Map<String, Any?> =
        mapOf("item" to missing(m.item), "progress" to m.progress, "done" to m.done, "error" to m.error)

    /** Base64 of 16-bit little-endian samples → samples (an odd trailing byte is dropped) */
    fun pcm16(base64: String): ShortArray {
        val bytes = Base64.getDecoder().decode(base64)
        val out = ShortArray(bytes.size / 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(out)
        return out
    }

    /** The `code` a failed call rejects with: the engine's own, else the call's [fallback] */
    fun errorCode(e: Throwable, fallback: String): String = (e as? EngineException)?.code ?: fallback
}
