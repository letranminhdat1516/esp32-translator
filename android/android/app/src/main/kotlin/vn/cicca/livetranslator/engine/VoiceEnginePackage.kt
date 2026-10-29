package vn.cicca.livetranslator.engine

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/** Registers [VoiceEngineModule] as the `VoiceEngine` TurboModule (added in MainApplication) */
class VoiceEnginePackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == NativeVoiceEngineSpec.NAME) VoiceEngineModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            NativeVoiceEngineSpec.NAME to ReactModuleInfo(
                name = NativeVoiceEngineSpec.NAME,
                className = VoiceEngineModule::class.java.name,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                isTurboModule = true,
            ),
        )
    }
}
