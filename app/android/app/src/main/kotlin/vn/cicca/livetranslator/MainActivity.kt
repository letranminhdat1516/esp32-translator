package vn.cicca.livetranslator

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import vn.cicca.livetranslator.engine.VoiceEnginePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The Android voice engine behind the pigeon VoiceEngineApi
        flutterEngine.plugins.add(VoiceEnginePlugin())
    }
}
