import SwiftUI
import Translation

struct ContentView: View {
    let engine: ConversationEngine

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBar(engine: engine)
                switch engine.phase {
                case .needsTranslationModels:
                    ModelDownloadView(engine: engine)
                case .preparing(let message):
                    Spacer()
                    ProgressView(message)
                    Spacer()
                case .failed(let message):
                    Spacer()
                    ContentUnavailableView("Không khởi động được", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                    Button("Thử lại") { Task { await engine.start() } }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                case .idle, .running:
                    ConversationView(engine: engine)
                }
            }
            .navigationTitle("Phiên dịch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xoá", systemImage: "trash") { engine.clearHistory() }
                        .disabled(engine.phase != .running)
                }
            }
        }
    }
}

private struct StatusBar: View {
    let engine: ConversationEngine

    var body: some View {
        HStack(spacing: 12) {
            Label(boardText, systemImage: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(engine.board == .ready ? .green : .secondary)
            Spacer()
            if engine.board == .ready {
                Button(engine.boardMicOn ? "Mic board: bật" : "Mic board: tắt",
                       systemImage: engine.boardMicOn ? "mic.fill" : "mic.slash.fill") {
                    engine.toggleBoardMic()
                }
                .buttonStyle(.bordered)
                .tint(engine.boardMicOn ? .green : .gray)
            }
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var boardText: String {
        switch engine.board {
        case .off: "Bluetooth tắt"
        case .scanning: "Đang tìm board…"
        case .connecting: "Đang kết nối…"
        case .ready: "Board đã kết nối"
        }
    }
}

private struct ConversationView: View {
    let engine: ConversationEngine

    var body: some View {
        VStack(spacing: 0) {
            Panel(title: "Họ nói", systemImage: "person.wave.2", tint: .blue,
                  lines: engine.theirLines, partial: engine.theirPartial)
            Divider()
            Panel(title: "Bạn nói → phụ đề trên board", systemImage: "airpodspro", tint: .green,
                  lines: engine.myLines, partial: "")
        }
    }
}

private struct Panel: View {
    let title: String
    let systemImage: String
    let tint: Color
    let lines: [ConversationEngine.Line]
    let partial: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal)
                .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.source).font(.subheadline).foregroundStyle(.secondary)
                                Text(line.target).font(.body.weight(.medium))
                            }
                            .id(line.id)
                        }
                        if !partial.isEmpty {
                            Text(partial).font(.subheadline).italic().foregroundStyle(.tertiary).id("partial")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .onChange(of: lines.last?.target) { scrollToEnd(proxy) }
                .onChange(of: partial) { scrollToEnd(proxy) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if !partial.isEmpty {
            proxy.scrollTo("partial", anchor: .bottom)
        } else if let id = lines.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

/// Tải gói dịch Anh ↔ Việt một lần (hệ thống hiện hộp thoại tải), sau đó dịch offline
private struct ModelDownloadView: View {
    let engine: ConversationEngine
    @State private var config: TranslationSession.Configuration?
    @State private var step = 0

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Cần tải gói dịch Anh ↔ Việt").font(.headline)
            Text("Tải một lần, sau đó dịch hoàn toàn trên máy, không cần mạng và nhanh hơn.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Tải gói dịch") {
                step = 1
                config = .init(source: ConversationEngine.english, target: ConversationEngine.vietnamese)
            }
            .buttonStyle(.borderedProminent)
            .disabled(step != 0)
            Spacer()
        }
        .padding()
        .translationTask(config) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                if step == 1 {
                    step = 2
                    config = .init(source: ConversationEngine.vietnamese, target: ConversationEngine.english)
                } else {
                    engine.translationModelsReady()
                }
            }
        }
    }
}
