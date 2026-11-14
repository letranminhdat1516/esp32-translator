import SwiftUI

// The part of the session that comes before the conversation: choosing a language, checking, missing downloads,
// downloading, failure. Shown by the Live screen in place of the transcript.

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
            spinner
        }
    }

    private var spinner: some View {
        VStack {
            Spacer()
            ProgressView().tint(DS.Color.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func choosing(_ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(ReadinessText.choose)
            if reason == "unavailable" {
                WarningBox(text: ReadinessText.unavailable).padding(.top, 10)
            }
            ScrollView { LanguageRows(ui: ui) }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, 8)
        }
    }

    private func needsDownload(missing: [MissingMsg], error: String?) -> some View {
        panel {
            SectionHeader(ReadinessText.needsDownloadTitle)
            RuledList {
                ForEach(Array(missing.enumerated()), id: \.offset) { _, m in
                    TableRow(verticalPadding: 10) {
                        Text(ReadinessText.missing(m, names: ui.languageNames)).ds(.row)
                    }
                }
            }
            .padding(.top, 8)
            Text(ReadinessText.needsDownloadNote).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                WarningBox(text: error.isEmpty ? ReadinessText.downloadFailed : ReadinessText.downloadFailed + "\n" + error)
            }
            InstrumentButton(ReadinessText.button(failed: error != nil), action: ui.download)
        }
    }

    private var downloading: some View {
        panel {
            SectionHeader(ReadinessText.progress(ui.downloadProgress))
            ProgressRule(fraction: ui.downloadProgress ?? 0).padding(.top, 4)
        }
    }

    private func failed(_ reason: String) -> some View {
        panel {
            SectionHeader(ReadinessText.failedTitle)
            WarningBox(text: ReadinessText.failureReason(reason))
            InstrumentButton(Copy.t("failed.retry"), action: ui.retry)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
