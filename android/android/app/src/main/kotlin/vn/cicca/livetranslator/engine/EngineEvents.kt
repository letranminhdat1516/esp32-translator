package vn.cicca.livetranslator.engine

/**
 * Where native components send their events. The app uses VoiceEngineModule's sink (the TurboModule's
 * generated emitters); tests record them. Any thread may call these.
 */
interface EngineEventSink {
    fun mine(msg: MineMsg) {}
    fun theirs(msg: TheirsMsg) {}
    fun gate(open: Boolean) {}
    fun ttsStart(id: Long) {}
    fun ttsEnd(id: Long) {}
    fun audioSession(msg: AudioSessionMsg) {}
    fun download(msg: DownloadMsg) {}
}
