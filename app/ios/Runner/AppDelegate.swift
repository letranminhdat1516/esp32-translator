import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// The native voice engine behind the pigeon `VoiceEngineApi`; lives as long as the app
  private var voiceEngine: VoiceEngineHost?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let host = VoiceEngineHost(events: .flutter(VoiceEngineEvents(binaryMessenger: messenger)))
    VoiceEngineApiSetup.setUp(binaryMessenger: messenger, api: host)
    voiceEngine = host
  }
}
