import Foundation
import Testing
@testable import TranslatorCore

/// Pairing by code (ARCHITECTURE §4): the state machine behind the Pair screen.
@Suite struct PairingMachineTests {
    private func connected() -> PairingMachine {
        var m = PairingMachine()
        m.start()
        m.handle(.scanning)
        m.handle(.connected(name: "ESP-Translator"))
        return m
    }

    @Test func newFirmwareHappyPath() {
        var m = PairingMachine()
        #expect(m.state == .idle)
        m.start()
        #expect(m.state == .scanning)
        m.handle(.connected(name: "ESP-Translator"))
        #expect(m.state == .found(name: "ESP-Translator", battery: nil))
        m.handle(.authenticating)
        #expect(m.state == .confirming(name: "ESP-Translator", battery: nil))
        m.handle(.authenticated)
        #expect(m.state == .paired(name: "ESP-Translator"))
    }

    /// Old firmware asks for no pairing: the read succeeds right away and the board is paired (pinned) as before
    @Test func oldFirmwareSucceedsWithoutADialog() {
        var m = connected()
        m.handle(.authenticating)
        m.handle(.authenticated)
        #expect(m.state == .paired(name: "ESP-Translator"))
    }

    @Test func refusalsAndRetry() {
        for failure in [PairingFailure.rejected, .timeout] {
            var m = connected()
            m.handle(.authenticating)
            m.handle(.authFailed(failure))
            #expect(m.state == .failed(failure))
            // Link events do not hide the failure until the user retries
            m.handle(.scanning)
            m.handle(.connected(name: "ESP-Translator"))
            #expect(m.state == .failed(failure))
            m.retry(connected: true)
            #expect(m.state == .confirming(name: "ESP-Translator", battery: nil))
            m.handle(.authenticated)
            #expect(m.state == .paired(name: "ESP-Translator"))
        }
    }

    @Test func retryWhileScanning() {
        var m = connected()
        m.handle(.authFailed(.rejected))
        m.retry(connected: false)
        #expect(m.state == .scanning)
        m.handle(.connected(name: "B"))
        #expect(m.state == .found(name: "B", battery: nil))
    }

    @Test func linkLostWhileConfirmingFails() {
        var m = connected()
        m.handle(.authenticating)
        m.handle(.linkLost)
        #expect(m.state == .failed(.lost))
        // Lost before the code: back to looking
        var n = connected()
        n.handle(.linkLost)
        #expect(n.state == .scanning)
    }

    @Test func timeoutOnlyWhileConfirming() {
        var m = connected()
        m.timedOut()
        #expect(m.state == .found(name: "ESP-Translator", battery: nil))
        m.handle(.authenticating)
        m.timedOut()
        #expect(m.state == .failed(.timeout))
    }

    @Test func bluetoothOffAndPairedIsSticky() {
        var m = connected()
        m.handle(.bluetoothOff)
        #expect(m.state == .failed(.bluetoothOff))
        var p = PairingMachine(state: .paired(name: "X"))
        for e: PairingLinkEvent in [.scanning, .connected(name: "X"), .linkLost, .bluetoothOff, .authFailed(.rejected)] {
            p.handle(e)
        }
        #expect(p.state == .paired(name: "X"))
        // Retry does nothing unless failed
        p.retry(connected: true)
        #expect(p.state == .paired(name: "X"))
    }

    @Test func batteryIsCarried() {
        var m = connected()
        m.battery(88)
        #expect(m.state == .found(name: "ESP-Translator", battery: 88))
        m.handle(.authenticating)
        #expect(m.state == .confirming(name: "ESP-Translator", battery: 88))
    }

    @Test func displayKeys() {
        #expect(PairDisplay(.scanning).bodyKey == "pair.bodyScanning")
        #expect(PairDisplay(.confirming(name: "A", battery: 5)).bodyKey == "pair.bodyConfirming")
        #expect(PairDisplay(.confirming(name: "A", battery: 5)).battery == 5)
        #expect(PairDisplay(.failed(.timeout)).bodyKey == "pair.bodyTimeout")
        #expect(PairDisplay(.failed(.rejected)).failed)
        #expect(PairDisplay(.paired(name: "A")).kickerKey == "pair.kickerPaired")
        for state: PairingState in [.idle, .scanning, .found(name: "A", battery: nil), .confirming(name: "A", battery: nil),
                                    .paired(name: "A"), .failed(.rejected), .failed(.timeout), .failed(.lost),
                                    .failed(.bluetoothOff)] {
            let d = PairDisplay(state)
            for key in [d.kickerKey, d.dialKey, d.noteKey, d.bodyKey] { #expect(Copy.t(key) != key, "\(key)") }
        }
    }
}

@MainActor @Suite struct LinkPairingModelTests {
    @Test func confirmationTimesOut() async throws {
        let m = LinkPairingModel(retryLink: { true }, timeout: 0.05)
        m.start()
        m.handle(.connected(name: "B"))
        m.handle(.authenticating)
        #expect(m.state == .confirming(name: "B", battery: nil))
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.state == .failed(.timeout))
        m.retry()
        #expect(m.state == .confirming(name: "B", battery: nil))
        m.handle(.authenticated)
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.state == .paired(name: "B"))   // the timer was cancelled
    }

    @Test func startActivatesTheLinkAndResetStartsOver() {
        var started = 0
        let m = LinkPairingModel(retryLink: { false }, onStart: { started += 1 })
        m.markPaired(name: "B")
        #expect(m.state == .paired(name: "B"))
        m.reset()
        #expect(m.state == .idle)
        m.start()
        #expect(started == 1)
        #expect(m.state == .scanning)
    }
}

@MainActor @Suite struct OnboardingRouterTests {
    @Test func theStepsAreAPushedStack() {
        let r = AppRouter(defaults: nil)
        #expect(r.onboardingPath.isEmpty)
        r.next()
        r.next()
        #expect(r.onboardingPath == [.permissions, .pair])
        // Swipe back pops one step
        r.onboardingPath = [.permissions]
        #expect(r.onboardingStep == .permissions)
        r.onboardingPath = []
        #expect(r.onboardingStep == .welcome)
    }

    @Test func languageStepFinishesOnboarding() {
        let name = "router-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        let r = AppRouter(defaults: d)
        r.onboardingStep = .language
        r.finishOnboarding()   // "Bắt đầu"
        #expect(r.onboardingDone)
        #expect(AppRouter(defaults: d).onboardingDone)
        d.removePersistentDomain(forName: name)
    }

    @Test func tryWithPhoneFromWelcome() {
        let r = AppRouter(defaults: nil)
        r.tryWithoutBoard()
        #expect(r.onboardingDone)
        #expect(r.mode == .phoneOnly)
    }

    @Test func unsupportedLanguagesAreTheBundledOnesNotOffered() {
        let names = ["vi": "Tiếng Việt", "en": "English", "th": "ไทย", "ar": "العربية"]
        let u = LanguageRowStatus.unsupported(names: names, offered: ["en"])
        #expect(u.map(\.code).sorted() == ["ar", "th"])
        #expect(LanguageRowStatus.unsupported(names: names, offered: ["en", "th", "ar"]).isEmpty)
        // A download in progress shows over an older explicit status
        #expect(LanguageRowStatus.resolve(code: "ja", explicit: .notDownloaded(megabytes: nil), session: .downloading("ja"),
                                          progress: 0.5) == .downloading(0.5))
    }
}
