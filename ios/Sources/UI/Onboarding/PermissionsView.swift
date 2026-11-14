import SwiftUI

/// 1.2 Cấp quyền. Track A wires the real permission state and requests (`request`).
struct PermissionsView: View {
    let router: AppRouter
    let permissions: PermissionsSnapshot
    var request: (PermissionsSnapshot.Kind) -> Void = { _ in }

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
            Text(Copy.t("perm.noAirPods")).ds(.monoNote).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Spacer(minLength: 16)
            Button(Copy.t("perm.continue")) { router.next() }
                .buttonStyle(.instrument())
                .disabled(!permissions.canContinue)
        }
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
            Button(Copy.t("perm.allow")) { request(kind) }
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
