import SwiftUI
import UIKit

/// 1.2 Cấp quyền: the real state of the three permissions; "Cho phép" shows the system prompt. "Tiếp tục" is
/// enabled only once all are granted; after a refusal (iOS asks only once) the button opens the app's Settings.
struct PermissionsView: View {
    let router: AppRouter
    let permissions: PermissionsSnapshot
    var actions = PermissionActions()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        InstrumentScreen {
            OnboardingStepBar(step: .permissions)
            ScreenTitle(Copy.t("perm.title")).padding(.top, 34)
            Text(Copy.t("perm.body")).ds(.paragraph).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            RuledList {
                ForEach(PermissionsSnapshot.Kind.allCases, id: \.self) { kind in row(kind) }
            }
            .padding(.top, 28)
            Text(Copy.t(permissions.anyDenied ? "perm.deniedNote" : "perm.noAirPods")).ds(.monoNote)
                .foregroundStyle(permissions.anyDenied ? DS.Color.warnText : DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Spacer(minLength: 16)
            switch permissions.primary {
            case .openSettings:
                Button(Copy.t("perm.openSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.instrument())
            case .continueOn, .waiting:
                Button(Copy.t("perm.continue")) { router.next() }
                    .buttonStyle(.instrument())
                    .disabled(!permissions.canContinue)
            }
        }
        .onAppear { actions.refresh() }
        // Back from the Settings app (or a system prompt): read the state again
        .onChange(of: scenePhase) { _, phase in if phase == .active { actions.refresh() } }
    }

    private func row(_ kind: PermissionsSnapshot.Kind) -> some View {
        let (icon, title, note): (DSIcon, String, String) = switch kind {
        case .microphone: (.mic, Copy.t("perm.mic"), Copy.t("perm.micNote"))
        case .bluetooth: (.bluetooth, Copy.t("perm.bluetooth"), Copy.t("perm.bluetoothNote"))
        case .speech: (.waveform, Copy.t("perm.speech"), Copy.t("perm.speechNote"))
        }
        return TableRow(verticalPadding: 16) {
            HStack(spacing: 12) {
                DSIconView(icon: icon, size: 24).tableColumn(40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).ds(.rowTitle)
                    Text(note).ds(.caption).foregroundStyle(DS.Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                trailing(kind)
            }
        }
    }

    @ViewBuilder
    private func trailing(_ kind: PermissionsSnapshot.Kind) -> some View {
        switch permissions.status(kind) {
        case .granted:
            StatusDot(color: DS.Color.blue, label: Copy.t("perm.granted"))
        case .denied:
            StatusDot(color: DS.Color.warnDot, label: Copy.t("perm.denied"), labelColor: DS.Color.warnText)
        case .notDetermined:
            Button(Copy.t("perm.allow")) { actions.request(kind) }
                .buttonStyle(.instrumentCompact(permissions.next == kind ? .primary : .secondary))
        }
    }
}

/// "Bước n/3" with the segments, for the onboarding steps.
struct OnboardingStepBar: View {
    let step: OnboardingStep

    var body: some View {
        let n = step.stepNumber ?? 1
        StepBar(progress: StepProgress(step: n, total: 3),
                label: Copy.t("step.label", ["n": String(n), "total": "3"]))
    }
}
