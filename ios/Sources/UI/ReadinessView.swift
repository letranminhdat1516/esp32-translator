import SwiftUI

// Port of app/lib/ui/readiness_view.dart: the part of the session that comes before the conversation: choosing a
// language, checking, missing downloads, downloading, failure.

struct ReadinessView: View {
    var ui: UIState
    let state: SessionState

    var body: some View {
        switch state {
        case let .choosing(reason):
            choosing(reason)
        case let .needsDownload(_, missing, error):
            needsDownload(missing: missing, error: error)
        case .downloading:
            downloading
        case let .failed(_, reason):
            failed(reason)
        case .loading, .checking, .preparing, .running, .switching:
            spinner(nil)
        }
    }

    private func spinner(_ text: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().tint(Palette.muted)
            if let text { Text(text).foregroundStyle(Palette.muted) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func choosing(_ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ReadinessText.choose).font(.system(size: 18, weight: .semibold))
                if reason == "unavailable" {
                    Text(ReadinessText.unavailable).font(.system(size: 14)).foregroundStyle(Palette.accentLight)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
            ScrollView {
                LanguageList(ui: ui, currentCode: nil, onPick: ui.pickLanguage)
            }
        }
    }

    private func needsDownload(missing: [MissingMsg], error: String?) -> some View {
        let failed = error != nil
        return centered {
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(Palette.accentLight)
            Text(ReadinessText.needsDownloadTitle)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            VStack(spacing: 6) {
                ForEach(Array(missing.enumerated()), id: \.offset) { _, m in
                    Text(ReadinessText.missing(m, names: ui.languageNames))
                        .font(.system(size: 15)).foregroundStyle(Palette.muted)
                }
            }
            Text(ReadinessText.needsDownloadNote)
                .font(.system(size: 15)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            if let error {
                Text(ReadinessText.downloadFailed)
                    .font(.system(size: 14)).foregroundStyle(Palette.accentLight).multilineTextAlignment(.center)
                if !error.isEmpty {
                    Text(error).font(.system(size: 13)).foregroundStyle(Palette.faint).multilineTextAlignment(.center)
                }
            }
            primaryButton(ReadinessText.button(failed: failed), action: ui.download)
        }
    }

    private var downloading: some View {
        centered {
            Group {
                if let p = ui.downloadProgress {
                    ProgressView(value: min(max(p, 0), 1))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .tint(Palette.accent)
            .frame(width: 220)
            Text(ReadinessText.progress(ui.downloadProgress)).font(.system(size: 15)).foregroundStyle(Palette.muted)
        }
    }

    private func failed(_ reason: String) -> some View {
        centered {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(Palette.muted)
            Text(ReadinessText.failedTitle).font(.system(size: 18, weight: .semibold))
            Text(ReadinessText.failureReason(reason))
                .font(.system(size: 15)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            primaryButton("Thử lại", action: ui.retry)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ScrollView {
                VStack(spacing: 14) { content() }
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 48)
                .background(Palette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

#if DEBUG
@MainActor private func readinessPreview(_ configure: (UIState) -> Void) -> some View {
    let ui = UIState.sampleChoosing()
    configure(ui)
    return ReadinessView(ui: ui, state: ui.session ?? .loading)
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
}

#Preview("Loading") { readinessPreview { $0.session = .loading } }
#Preview("Choosing") { readinessPreview { _ in } }
#Preview("Choosing, saved language gone") { readinessPreview { $0.session = .choosing(reason: "unavailable") } }
#Preview("Needs download") {
    readinessPreview { $0.session = .needsDownload("ja", missing: UIState.sampleMissing) }
}
#Preview("Needs download, failed") {
    readinessPreview {
        $0.session = .needsDownload("ja", missing: UIState.sampleMissing, error: "Không có kết nối mạng (-1009)")
    }
}
#Preview("Downloading") {
    readinessPreview {
        $0.session = .downloading("ja")
        $0.downloadProgress = 0.42
    }
}
#Preview("Failed") {
    readinessPreview { $0.session = .failed("ja", reason: "recognizer stopped") }
}
#endif
