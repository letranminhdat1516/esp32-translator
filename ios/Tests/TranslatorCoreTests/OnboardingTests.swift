import Foundation
import Testing
@testable import TranslatorCore

/// Pairing by code (ARCHITECTURE §4): the state machine behind the Pair screen.
@Suite struct PairingMachineTests {
    private static let boardID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
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

    /// Old firmware asks for no pairing: the read proves nothing, so the link asks the user before pinning
    @Test func oldFirmwareAsksForConsent() {
        var m = connected()
        m.handle(.authenticating)
        m.handle(.legacyBoard(id: Self.boardID, gen: 1))
        #expect(m.state == .legacyConsent(name: "ESP-Translator", id: Self.boardID, gen: 1))
        m.timedOut()                                              // no confirm timer on the warning
        #expect(m.state == .legacyConsent(name: "ESP-Translator", id: Self.boardID, gen: 1))
        m.acceptLegacy()
        #expect(m.state == .found(name: "ESP-Translator", battery: nil))
        m.handle(.authenticated)
        #expect(m.state == .paired(name: "ESP-Translator"))
    }

    @Test func huyOnTheOldFirmwareWarningFailsAndRetryLooksAgain() {
        var m = connected()
        m.handle(.legacyBoard(id: Self.boardID, gen: 1))     // no control characteristic: no read at all
        m.declineLegacy()
        #expect(m.state == .failed(.declined))
        m.handle(.linkLost)
        m.handle(.scanning)
        #expect(m.state == .failed(.declined))
        m.retry(connected: false)
        #expect(m.state == .scanning)
        // Answers outside the warning do nothing
        m.acceptLegacy()
        m.declineLegacy()
        #expect(m.state == .scanning)
    }

    @Test func linkLostOnTheOldFirmwareWarningFails() {
        var m = connected()
        m.handle(.legacyBoard(id: Self.boardID, gen: 1))
        m.handle(.linkLost)
        #expect(m.state == .failed(.lost))
        var n = connected()
        n.handle(.legacyBoard(id: Self.boardID, gen: 1))
        n.handle(.scanning)
        #expect(n.state == .failed(.lost))
    }

    /// The pinned secure board came back as old firmware: shown even though the screen was paired
    @Test func aPairedBoardThatNoLongerAuthenticatesIsShown() {
        var m = PairingMachine(state: .paired(name: "X"))
        m.handle(.authFailed(.unverified))
        #expect(m.state == .failed(.unverified))
        m.handle(.scanning)
        m.handle(.connected(name: "X"))
        m.handle(.legacyBoard(id: Self.boardID, gen: 1))
        #expect(m.state == .failed(.unverified))
        // The board later proves itself again
        m.handle(.authenticated)
        #expect(m.state == .paired(name: "X"))
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
        #expect(PairDisplay(.legacyConsent(name: "A", id: UUID(), gen: 0)).legacy)
        #expect(PairDisplay(.legacyConsent(name: "A", id: UUID(), gen: 0)).bodyKey == "pair.bodyLegacy")
        #expect(PairDisplay(.legacyConsent(name: "A", id: UUID(), gen: 0)).name == "A")
        #expect(PairDisplay(.failed(.unverified)).bodyKey == "pair.bodyUnverified")
        #expect(PairDisplay(.failed(.declined)).bodyKey == "pair.bodyDeclined")
        #expect(PairDisplay(.failed(.refusedByBoard)).bodyKey == "pair.bodyRefusedByBoard")
        #expect(PairDisplay(.failed(.refusedByBoard)).failed)
        #expect(Copy.t("pair.bodyRefusedByBoard").hasPrefix("Board đang từ chối ghép, thử lại sau ít phút"))
        #expect(PairDisplay(.confirming(name: "A", battery: nil)).dialogHintKey == "pair.dialogRequired")
        #expect(PairDisplay(.found(name: "A", battery: nil)).dialogHintKey == "pair.dialogRequired")
        #expect(PairDisplay(.legacyConsent(name: "A", id: UUID(), gen: 0)).dialogHintKey == nil)
        #expect(PairDisplay(.paired(name: "A")).dialogHintKey == nil)
        for state: PairingState in [.idle, .scanning, .found(name: "A", battery: nil), .confirming(name: "A", battery: nil),
                                    .paired(name: "A"), .failed(.rejected), .failed(.timeout), .failed(.lost),
                                    .failed(.bluetoothOff), .failed(.declined), .failed(.unverified),
                                    .failed(.refusedByBoard), .legacyConsent(name: "A", id: UUID(), gen: 0)] {
            let d = PairDisplay(state)
            for key in [d.kickerKey, d.dialKey, d.noteKey, d.bodyKey] + [d.dialogHintKey].compactMap({ $0 }) {
                #expect(Copy.t(key) != key, "\(key)")
            }
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

    private struct Answer: Equatable { var id: UUID; var gen: Int; var accept: Bool }
    private static let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private static let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    /// The answer carries the peripheral and link generation the question was asked on
    @Test func theOldFirmwareAnswerGoesToTheLink() {
        var answers: [Answer] = []
        let m = LinkPairingModel(retryLink: { false }, consent: { answers.append(Answer(id: $0, gen: $1, accept: $2)) })
        m.start()
        m.acceptLegacy()                                          // not asked: nothing sent
        #expect(answers.isEmpty)
        m.handle(.connected(name: "B"))
        m.handle(.legacyBoard(id: Self.b, gen: 3))
        #expect(m.state == .legacyConsent(name: "B", id: Self.b, gen: 3))
        m.acceptLegacy()
        #expect(answers == [Answer(id: Self.b, gen: 3, accept: true)])
        m.handle(.authenticated)
        #expect(m.state == .paired(name: "B"))
        m.reset()
        m.start()
        m.handle(.connected(name: "C"))
        m.handle(.legacyBoard(id: Self.c, gen: 7))
        m.declineLegacy()
        #expect(answers == [Answer(id: Self.b, gen: 3, accept: true), Answer(id: Self.c, gen: 7, accept: false)])
        #expect(m.state == .failed(.declined))
    }

    /// The link dropped while the warning was up and a new link asks again: the answer names the new question
    @Test func aReaskReplacesTheQuestion() {
        var answers: [Answer] = []
        let m = LinkPairingModel(retryLink: { false }, consent: { answers.append(Answer(id: $0, gen: $1, accept: $2)) })
        m.start()
        m.handle(.connected(name: "B"))
        m.handle(.legacyBoard(id: Self.b, gen: 1))
        m.handle(.linkLost)                                       // the warning fails: no answer for gen 1 is sent
        m.acceptLegacy()
        #expect(answers.isEmpty)
        m.retry()
        m.handle(.connected(name: "C"))
        m.handle(.legacyBoard(id: Self.c, gen: 4))
        m.acceptLegacy()
        #expect(answers == [Answer(id: Self.c, gen: 4, accept: true)])
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
