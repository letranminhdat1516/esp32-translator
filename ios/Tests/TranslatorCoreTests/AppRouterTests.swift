import Foundation
import Testing
@testable import TranslatorCore

@MainActor @Suite struct AppRouterTests {
    private func defaults() -> UserDefaults {
        let name = "router-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func freshInstallStartsOnboarding() {
        let r = AppRouter(defaults: defaults())
        #expect(!r.onboardingDone)
        #expect(r.onboardingStep == .welcome)
    }

    @Test func existingUserWithASavedLanguageSkipsOnboarding() {
        let d = defaults()
        d.set("en", forKey: ConversationController.pickKey)
        #expect(AppRouter(defaults: d).onboardingDone)
    }

    @Test func onboardingWalksTheStepsAndPersists() {
        let d = defaults()
        let r = AppRouter(defaults: d)
        r.next()
        #expect(r.onboardingStep == .permissions)
        r.next()
        r.next()
        #expect(r.onboardingStep == .language)
        r.back()
        #expect(r.onboardingStep == .pair)
        r.next()
        r.next()
        #expect(r.onboardingDone)
        #expect(d.bool(forKey: AppRouter.onboardingKey))
        #expect(AppRouter(defaults: d).onboardingDone)
    }

    @Test func stepNumbers() {
        #expect(OnboardingStep.welcome.stepNumber == nil)
        #expect(OnboardingStep.permissions.stepNumber == 1)
        #expect(OnboardingStep.language.stepNumber == 3)
    }

    @Test func tryWithoutBoardGoesPhoneOnly() {
        let r = AppRouter(defaults: nil)
        r.tryWithoutBoard()
        #expect(r.onboardingDone)
        #expect(r.mainScreen(board: .off) == .phoneOnly)
        r.noteBoard(.ready)
        #expect(r.mode == .board)
        #expect(r.mainScreen(board: .ready) == .live)
    }

    @Test func connectBoardFromPhoneOnlyOpensPair() {
        let defaults = UserDefaults(suiteName: "AppRouterTests.connect.\(UUID().uuidString)")!
        let r = AppRouter(defaults: defaults)
        r.tryWithoutBoard()
        r.connectBoard()
        #expect(!r.onboardingDone)
        #expect(r.onboardingStep == .pair)
        #expect(r.mode == .board)
        #expect(defaults.bool(forKey: AppRouter.onboardingKey), "a relaunch opens the main screen again")
    }

    @Test func mainScreenFollowsTheBoard() {
        #expect(MainScreen.resolve(mode: .board, board: .off, wasReady: false, lostDismissed: false) == .live)
        #expect(MainScreen.resolve(mode: .board, board: .ready, wasReady: true, lostDismissed: false) == .live)
        #expect(MainScreen.resolve(mode: .board, board: .scanning, wasReady: true, lostDismissed: false) == .boardLost)
        #expect(MainScreen.resolve(mode: .board, board: .connecting, wasReady: true, lostDismissed: true) == .phoneOnly)
        #expect(MainScreen.resolve(mode: .phoneOnly, board: .off, wasReady: false, lostDismissed: false) == .phoneOnly)
    }

    @Test func losingAConnectedBoardShowsTheLostScreenUntilDismissed() {
        let r = AppRouter(defaults: nil)
        r.finishOnboarding()
        r.noteBoard(.connecting)
        #expect(r.mainScreen(board: .connecting) == .live)
        r.noteBoard(.ready)
        r.noteBoard(.scanning)
        #expect(r.mainScreen(board: .scanning) == .boardLost)
        r.continueWithPhone()
        #expect(r.mainScreen(board: .scanning) == .phoneOnly)
        r.noteBoard(.ready)
        #expect(r.mainScreen(board: .ready) == .live)
        #expect(!r.boardLostDismissed)
    }

    @Test func navigationPathAndSheet() {
        let r = AppRouter(defaults: nil)
        r.push(.settings)
        r.push(.glossary)
        #expect(r.path == [.settings, .glossary])
        r.pop()
        #expect(r.path == [.settings])
        r.push(.historyDetail("x"))
        r.popToRoot()
        #expect(r.path.isEmpty)
        r.pop()
        #expect(r.path.isEmpty)
        r.sheet = .language
        #expect(r.sheet?.id == "language")
    }

    @Test func forgettingTheBoardRestartsPairing() {
        let d = defaults()
        let r = AppRouter(defaults: d)
        r.finishOnboarding()
        r.noteBoard(.ready)
        r.push(.settings)
        r.restartPairing()
        #expect(!r.onboardingDone)
        #expect(r.onboardingStep == .pair)
        #expect(r.path.isEmpty)
        #expect(!r.wasBoardReady)
        #expect(!d.bool(forKey: AppRouter.onboardingKey))
    }

    @Test func demoArgumentParsing() {
        #expect(DemoScreen.parse(["app", "-demo", "live"]) == .live)
        #expect(DemoScreen.parse(["app", "--demo", "BoardLost"]) == .boardlost)
        #expect(DemoScreen.parse(["app", "-demo"]) == nil)
        #expect(DemoScreen.parse(["app", "-demo", "nope"]) == nil)
        #expect(DemoScreen.parse(["app"]) == nil)
        #expect(DemoScreen.allCases.count == 12)
    }

    @Test func demoOpensEveryScreen() {
        for screen in DemoScreen.allCases {
            let r = AppRouter(defaults: nil)
            r.apply(screen)
            switch screen {
            case .welcome, .permissions, .pair, .language:
                #expect(!r.onboardingDone)
                #expect(r.onboardingStep == screen.onboardingStep)
            case .live: #expect(r.onboardingDone && r.path.isEmpty && r.mainScreen(board: .ready) == .live)
            case .lock: #expect(r.lockPreview)
            case .phoneonly: #expect(r.mainScreen(board: .off) == .phoneOnly)
            case .boardlost: #expect(r.mainScreen(board: .scanning) == .boardLost)
            case .history: #expect(r.path.last == .history)
            case .glossary: #expect(r.path.last == .glossary)
            case .settings: #expect(r.path == [.settings])
            case .sharing: #expect(r.path.last == .sharing)
            }
        }
    }

    @Test func demoSeedFillsTheCanvasData() {
        let ui = UIState()
        let services = AppServices(appVersion: "0.9")
        DemoData.seed(.live, ui: ui, services: services)
        #expect(ui.lines.count == 3)
        #expect(ui.session == .running("en"))
        #expect(services.historySessions.count == 4)
        #expect(services.feedbackItems.filter(\.selected).count == 2)
        #expect(services.level.level > 0.5)
        #expect(services.selectedLineID == "d3")
        ui.startStop()
        #expect(!ui.listening)
        let lost = UIState()
        DemoData.seed(.boardlost, ui: lost, services: AppServices())
        #expect(lost.board == .scanning)
        #expect(HistoryFormatting.secondsAgo(lost.boardLostAt!, now: DemoData.now) == 12)
    }
}
