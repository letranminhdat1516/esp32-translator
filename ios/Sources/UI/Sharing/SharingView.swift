import AVFoundation
import SwiftUI
import UIKit

/// 3.4 Chia sẻ dữ liệu: the "Báo dịch sai" queue, choose what to send, export through the share sheet (there is
/// no server). "Gửi n câu" builds `feedback-<date>/` (items.json + NN.wav), zips it and opens the share sheet.
struct SharingView: View {
    let ui: UIState
    let router: AppRouter
    let services: AppServices
    @State private var player = ClipPlayer()
    @State private var export: ExportFile?
    @State private var exporting = false
    @State private var confirmClear = false
    @State private var error: String?

    private var items: [FeedbackItem] { services.feedbackItems }
    private var selectedCount: Int { FeedbackItem.selectedCount(items) }
    private var sentCount: Int { items.filter { $0.sentAt != nil }.count }

    var body: some View {
        InstrumentScreen {
            TopBar { BackLink(title: Copy.t("nav.back")) { router.pop() } } trailing: {
                Toggle(isOn: Binding(get: { ui.shareToImprove }, set: ui.setShareToImprove)) {
                    Text(Copy.t("sharing.allow"))
                }
                .toggleStyle(.instrument)
            }
            ScreenTitle(Copy.t("sharing.title")).padding(.top, 6)
            Text(Copy.t("sharing.body")).ds(.small).foregroundStyle(DS.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            WarningBox(text: Copy.t("sharing.warning")).padding(.top, 14)
            SectionHeader(Copy.t("sharing.reported", ["count": String(items.count)])).padding(.top, 20)
            ScrollView {
                if items.isEmpty {
                    Text(Copy.t("sharing.empty")).ds(.small).foregroundStyle(DS.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                } else {
                    RuledList {
                        ForEach(items) { item in row(item) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 8)
            Spacer(minLength: 12)
            if let error {
                Text(error).ds(.caption).foregroundStyle(DS.Color.warnText).padding(.bottom, 8)
            }
            VStack(spacing: DS.Space.buttonGap) {
                InstrumentButton(Copy.t("sharing.send", ["count": String(selectedCount)]), action: send)
                    .disabled(selectedCount == 0 || exporting)
                Button { confirmClear = true } label: {
                    Text(Copy.t("sharing.clearSent")).ds(.button, scales: false).underline()
                        .foregroundStyle(DS.Color.warnText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
            }
        }
        .task { await services.refresh() }
        .onDisappear { player.stop() }
        .sheet(item: $export) { file in
            ActivitySheet(items: [file.url]).ignoresSafeArea()
        }
        .confirmationDialog(Copy.t("sharing.clearTitle"), isPresented: $confirmClear, titleVisibility: .visible) {
            if sentCount > 0 {
                Button(Copy.t("sharing.clearSentOnly", ["count": String(sentCount)]), role: .destructive) {
                    player.stop()
                    Task { await services.removeSentFeedback() }
                }
            }
            Button(Copy.t("sharing.clearAll"), role: .destructive) {
                player.stop()
                Task { await services.removeAllFeedback() }
            }
            Button(Copy.t("dialog.cancel"), role: .cancel) {}
        }
    }

    private func send() {
        error = nil
        exporting = true
        Task {
            defer { exporting = false }
            guard let folder = await services.exportFeedback() else {
                error = Copy.t("sharing.exportFailed")
                return
            }
            export = ExportFile(url: ExportFile.zipped(folder) ?? folder)
        }
    }

    private func play(_ item: FeedbackItem) {
        error = nil
        Task {
            guard let url = await services.feedback.clipURL(item.id), player.toggle(url, id: item.id) else {
                error = Copy.t("sharing.playFailed")
                return
            }
        }
    }

    private func row(_ item: FeedbackItem) -> some View {
        TableRow(verticalPadding: 12) {
            HStack(spacing: 12) {
                Button { Task { await services.toggleFeedback(item) } } label: {
                    InstrumentCheckbox(isOn: item.selected).frame(width: 24, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.t("sharing.select"))
                .accessibilityValue(item.selected ? Text(Copy.t("settings.on")) : Text(Copy.t("settings.off")))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.expected.isEmpty ? item.heard : item.heard + " \u{2192} " + item.expected)
                        .ds(DSType.row.with(weight: 700)).lineSpacing(0)
                        .lineLimit(2)
                    Text(subtitle(item)).ds(.caption)
                        .foregroundStyle(item.sensitive ? DS.Color.warnText : DS.Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button { play(item) } label: {
                    Group {
                        if player.playingID == item.id {
                            RoundedRectangle(cornerRadius: 1).fill(DS.Color.ink).frame(width: 10, height: 10)
                        } else {
                            DSIconView(icon: .play, size: 12)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.smallButton, style: .continuous)
                        .strokeBorder(DS.Color.ink, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.clipFile == nil)
                .opacity(item.clipFile == nil ? 0.35 : 1)
                .accessibilityLabel(Copy.t("sharing.play"))
            }
        }
    }

    private func subtitle(_ item: FeedbackItem) -> String {
        var parts = [Copy.t(item.mine ? "bubble.mine" : "bubble.theirs")]
        if item.sensitive {
            parts.append(Copy.t("sharing.sensitive"))
        } else if let s = item.clipSeconds {
            parts.append(Copy.t("sharing.seconds", ["seconds": String(max(1, Int(s.rounded())))]))
        }
        if item.sentAt != nil { parts.append(Copy.t("sharing.sent")) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The exported bundle handed to the share sheet.
struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }

    /// `folder` as a .zip beside it (the system zips a folder read "for uploading"); nil when that fails, and the
    /// folder itself is shared instead.
    static func zipped(_ folder: URL) -> URL? {
        var result: URL?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { tmp in
            let dst = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: tmp, to: dst)
                result = dst
            } catch {
                Diag.log("feedback: zip copy failed: \(error)")
            }
        }
        if let coordinatorError { Diag.log("feedback: zip failed: \(coordinatorError)") }
        return result
    }
}

/// `UIActivityViewController` (AirDrop, Mail, Files…).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Plays one queued clip at a time.
@Observable @MainActor
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// Plays `url`, or stops when `id` is already playing. False when the file cannot be played.
    @discardableResult
    func toggle(_ url: URL, id: String) -> Bool {
        if playingID == id {
            stop()
            return true
        }
        stop()
        do {
            // During a conversation the engine's play-and-record session is left alone (the clip plays through it)
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            guard p.play() else { return false }
            player = p
            playingID = id
            return true
        } catch {
            Diag.log("feedback: playback failed: \(error)")
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
