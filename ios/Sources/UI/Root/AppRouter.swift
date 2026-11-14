import Foundation
import Observation

// Navigation state of the app (no SwiftUI here, so it is unit-tested): onboarding vs main, the screen the main
// part shows for the board state, the pushed screens and the sheets.

enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
    case welcome, permissions, pair, language

    /// "Bước n/3" (the welcome screen has no step bar).
    var stepNumber: Int? { self == .welcome ? nil : rawValue }
}

/// Screens pushed on the main navigation stack (Settings → Glossary/History/Sharing, Live → History).
enum Route: Hashable, Sendable {
    case settings, history, historyDetail(String), glossary, sharing, language
}

enum AppSheet: String, Hashable, Identifiable, Sendable {
    /// The language list from Live's "EN ▾".
    case language
    var id: String { rawValue }
}

/// How the user chose to run: with the board, or phone only ("Dùng thử bằng iPhone", "Dùng iPhone trong lúc chờ").
enum MainMode: Hashable, Sendable { case board, phoneOnly }

/// What the main part shows.
enum MainScreen: Hashable, Sendable {
    case live, phoneOnly, boardLost

    /// Board connection states → screens (ARCHITECTURE §3): ready → Live; scanning/connecting after having been
    /// ready → the lost screen until the user picks "Dùng iPhone trong lúc chờ" (then phone only); never connected
    /// → Live (the conversation works without a board, with the "không có board" chip).
    static func resolve(mode: MainMode, board: BoardState, wasReady: Bool, lostDismissed: Bool) -> MainScreen {
        if mode == .phoneOnly { return .phoneOnly }
        if board == .ready || !wasReady { return .live }
        return lostDismissed ? .phoneOnly : .boardLost
    }
}

@Observable @MainActor
final class AppRouter {
    static let onboardingKey = "onboarding.done"

    private(set) var onboardingDone: Bool
    var onboardingStep: OnboardingStep = .welcome
    var path: [Route] = []
    var sheet: AppSheet?
    var mode: MainMode = .board
    /// The board was connected during this run (so losing it shows the lost screen).
    private(set) var wasBoardReady = false
    /// The user chose to carry on with the iPhone while the board is lost.
    var boardLostDismissed = false
    /// "Xoá hội thoại?" confirmation.
    var confirmClear = false
    /// Demo mode only: show the Live Activity lock-screen preview instead of the app.
    var lockPreview = false

    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults` nil: nothing is persisted (demo mode, tests). Someone who already picked a language with the old
    /// screen counts as onboarded.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        onboardingDone = (defaults?.bool(forKey: Self.onboardingKey) ?? false)
            || defaults?.string(forKey: ConversationController.pickKey) != nil
    }

    // MARK: Onboarding

    func next() {
        guard let n = OnboardingStep(rawValue: onboardingStep.rawValue + 1) else {
            finishOnboarding()
            return
        }
        onboardingStep = n
    }

    func back() {
        if let p = OnboardingStep(rawValue: onboardingStep.rawValue - 1) { onboardingStep = p }
    }

    func finishOnboarding() {
        onboardingDone = true
        defaults?.set(true, forKey: Self.onboardingKey)
    }

    /// "Chưa có board? Dùng thử bằng iPhone": straight to phone-only.
    func tryWithoutBoard() {
        mode = .phoneOnly
        finishOnboarding()
    }

    /// Back to the pair step (after "Quên board này").
    func restartPairing() {
        path.removeAll()
        sheet = nil
        wasBoardReady = false
        boardLostDismissed = false
        mode = .board
        onboardingStep = .pair
        onboardingDone = false
        defaults?.set(false, forKey: Self.onboardingKey)
    }

    // MARK: Main

    func noteBoard(_ state: BoardState) {
        if state == .ready {
            wasBoardReady = true
            boardLostDismissed = false
            if mode == .phoneOnly { mode = .board }
        }
    }

    func mainScreen(board: BoardState) -> MainScreen {
        MainScreen.resolve(mode: mode, board: board, wasReady: wasBoardReady, lostDismissed: boardLostDismissed)
    }

    /// "Dùng iPhone trong lúc chờ".
    func continueWithPhone() { boardLostDismissed = true }

    /// "Kết nối board" from phone-only.
    func connectBoard() {
        mode = .board
        boardLostDismissed = false
    }

    func push(_ route: Route) { path.append(route) }

    func pop() { _ = path.popLast() }

    func popToRoot() { path.removeAll() }

    // MARK: Demo

    /// Puts the router on `screen` (demo mode; nothing is persisted).
    func apply(_ screen: DemoScreen) {
        path = []
        sheet = nil
        lockPreview = false
        switch screen {
        case .welcome, .permissions, .pair, .language:
            onboardingDone = false
            onboardingStep = screen.onboardingStep ?? .welcome
        default:
            onboardingDone = true
        }
        switch screen {
        case .lock: lockPreview = true
        case .phoneonly: mode = .phoneOnly
        case .boardlost:
            mode = .board
            wasBoardReady = true
            boardLostDismissed = false
        case .history: path = [.history]
        case .glossary: path = [.settings, .glossary]
        case .settings: path = [.settings]
        case .sharing: path = [.settings, .sharing]
        default: break
        }
    }
}
