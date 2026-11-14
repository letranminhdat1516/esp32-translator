import Foundation

/// Starts, updates and ends the Live Activity. Track D implements the ActivityKit version with coalescing (≤ 1
/// update per 1.5 s, latest phrase pair only, ≤ 4 KB).
@MainActor
protocol LiveActivityControlling: AnyObject {
    func start(languageCode: String, languageName: String, state: TranslatorActivityState)
    func update(_ state: TranslatorActivityState)
    func end()
}

/// Does nothing (demo mode, tests, devices without Live Activities).
@MainActor
final class NoopLiveActivityController: LiveActivityControlling {
    private(set) var lastState: TranslatorActivityState?
    init() {}
    func start(languageCode: String, languageName: String, state: TranslatorActivityState) { lastState = state }
    func update(_ state: TranslatorActivityState) { lastState = state }
    func end() { lastState = nil }
}
