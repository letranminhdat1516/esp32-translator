import SwiftUI

/// Routes between onboarding and the main part, holds the navigation stack (Live → Settings → Glossary / History /
/// Sharing) and the sheets. Every view reads only what it draws.
struct RootView: View {
    let ui: UIState
    @Bindable var router: AppRouter
    let services: AppServices
    /// Forget the pinned board (the link) and go back to pairing.
    var forgetBoard: () -> Void

    var body: some View {
        content
            .preferredColorScheme(.light)
            .tint(DS.Color.ink)
            .onChange(of: ui.board, initial: true) { _, state in router.noteBoard(state) }
            // Phone-only follows the screen shown (ARCHITECTURE §5): the engine moves the iPhone mic to them
            .onChange(of: router.mainScreen(board: ui.board) == .phoneOnly, initial: true) { _, on in ui.setPhoneOnly(on) }
            .feedbackReporting(ui)   // Track C: "Báo dịch sai" sheet
            .sheet(item: $router.sheet) { sheet in
                switch sheet {
                case .language:
                    LanguageView(ui: ui, router: router, mode: .sheet)
                        .presentationDetents([.large])
                        .presentationBackground(DS.Color.stone)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if router.lockPreview, let a = services.activity {
            LockScreenPreview(info: a.info, state: a.state, now: services.now())
        } else if !router.onboardingDone {
            onboarding
        } else {
            NavigationStack(path: $router.path) {
                main
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { route in
                        destination(route).toolbar(.hidden, for: .navigationBar)
                    }
            }
        }
    }

    /// Welcome at the root, the steps pushed (swipe back works with the bar hidden: `SwipeBack.swift`).
    private var onboarding: some View {
        NavigationStack(path: $router.onboardingPath) {
            onboardingScreen(.welcome)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: OnboardingStep.self) { step in
                    onboardingScreen(step).toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    @ViewBuilder
    private func onboardingScreen(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeView(router: router)
        case .permissions:
            PermissionsView(router: router, permissions: services.permissions, actions: services.permissionActions)
        case .pair: PairView(router: router, pairing: services.pairing)
        case .language: LanguageView(ui: ui, router: router, mode: .onboarding)
        }
    }

    @ViewBuilder
    private var main: some View {
        switch router.mainScreen(board: ui.board) {
        case .live: LiveView(ui: ui, router: router, services: services)
        case .phoneOnly: PhoneOnlyView(ui: ui, router: router, partials: services.partials)
        case .boardLost: BoardLostView(ui: ui, router: router, now: services.now, forget: forgetBoard)
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .settings:
            SettingsView(ui: ui, router: router, appVersion: services.appVersion, forget: forgetBoard)
        case .history:
            HistoryView(router: router, services: services, saving: ui.saveHistory)
        case let .historyDetail(id):
            HistoryDetailView(router: router, services: services, sessionID: id)
        case .glossary:
            GlossaryView(ui: ui, router: router, draft: services.glossaryDraft)
        case .sharing:
            SharingView(ui: ui, router: router, services: services)
        case .language:
            LanguageView(ui: ui, router: router, mode: .pushed)
        }
    }
}
