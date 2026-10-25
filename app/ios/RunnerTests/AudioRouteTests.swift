import AVFAudio
import XCTest
@testable import Runner

/// AVAudioSession routes exist only on iOS, so these run in RunnerTests only (not in app/ios/NativeTests)
final class AudioRouteTests: XCTestCase {
    func testRouteIsHeadsetForBluetoothAndWiredMics() {
        XCTAssertEqual(EngineMapping.route(inputs: [.bluetoothHFP]), .headset)
        XCTAssertEqual(EngineMapping.route(inputs: [.headsetMic]), .headset)
        XCTAssertEqual(EngineMapping.route(inputs: [.builtInMic]), .phoneMic)
        XCTAssertEqual(EngineMapping.route(inputs: []), .phoneMic)
    }

    func testOnlyDeviceChangesAreReportedAsRouteChanges() {
        XCTAssertTrue(EngineMapping.reportsRouteChange(.newDeviceAvailable))
        XCTAssertTrue(EngineMapping.reportsRouteChange(.oldDeviceUnavailable))
        // Our own setCategory calls change the category: not a route change for Dart
        XCTAssertFalse(EngineMapping.reportsRouteChange(.categoryChange))
    }
}
