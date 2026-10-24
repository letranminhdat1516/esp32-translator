import SwiftUI
import Translation

/// "Phụ đề" style: black, text first, one blue accent (the board's) that lights only while listening.
private enum Palette {
    static let ground = Color.black
    static let surface = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255)
    static let text = Color(red: 0xE3 / 255, green: 0xEA / 255, blue: 0xF0 / 255)
    static let muted = Color(red: 0x8A / 255, green: 0x91 / 255, blue: 0x9C / 255)
    static let faint = Color(red: 0x5E / 255, green: 0x64 / 255, blue: 0x6D / 255)
    static let accent = Color(red: 0x1E / 255, green: 0x6F / 255, blue: 0xD9 / 255)
    static let accentLight = Color(red: 0x4C / 255, green: 0x8F / 255, blue: 0xE8 / 255)
}

struct ContentView: View {
    let engine: ConversationEngine
    let relay: RelayModel
    @State private var showRelay = false
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            Header(engine: engine, showRelay: $showRelay, confirmClear: $confirmClear)
            switch engine.phase {
            case .needsTranslationModels:
                ModelDownloadView(engine: engine)
            case .preparing(let message):
                Spacer()
                ProgressView(message).tint(Palette.muted).foregroundStyle(Palette.muted)
                Spacer()
            case .failed(let message):
                Spacer()
                ContentUnavailableView("Không khởi động được", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                Button("Thử lại") { Task { await engine.start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                Spacer()
            case .idle, .running:
                ConversationView(engine: engine)
                ControlBar(engine: engine, confirmClear: $confirmClear)
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRelay) { RelayView(model: relay) }
        // The trash sits next to the listen button: a stray tap must not wipe the conversation
        .confirmationDialog("Xoá toàn bộ hội thoại?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { engine.clearHistory() }
            Button("Huỷ", role: .cancel) {}
        }
    }
}

private extension ConversationEngine {
    var hasHistory: Bool { !theirLines.isEmpty || !myLines.isEmpty }
}

/// Language pair, settings, and one status line: listening · board
private struct Header: View {
    let engine: ConversationEngine
    @Binding var showRelay: Bool
    @Binding var confirmClear: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Text("Tiếng Việt")
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.muted)
                    Text("English")
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Palette.surface, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tiếng Việt sang English")
                Spacer()
                Menu {
                    Button("Claude relay", systemImage: "point.3.connected.trianglepath.dotted") { showRelay = true }
                    Button("Xoá hội thoại", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(engine.phase != .running || !engine.hasHistory)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                        .background(Palette.surface, in: Circle())
                }
                .accessibilityLabel("Cài đặt")
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.listening ? Palette.accentLight : Palette.faint)
                    .frame(width: 8, height: 8)
                Text(engine.listening ? "Đang nghe" : "Đang chờ")
                    .fontWeight(.semibold)
                    .foregroundStyle(engine.listening ? Palette.text : Palette.muted)
                Text("· \(boardText)").foregroundStyle(Palette.muted)
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var boardText: String {
        switch engine.board {
        case .off: "Bluetooth đang tắt"
        case .scanning: "Đang tìm board…"
        case .connecting: "Đang kết nối…"
        case .ready: engine.boardMicOn ? "Board đã kết nối" : "Board đã kết nối · mic tắt"
        }
    }
}

/// Both sides in one stream, oldest first: their lines on the left, yours on the right
private struct ConversationView: View {
    let engine: ConversationEngine

    private struct Entry: Identifiable {
        let line: ConversationEngine.Line
        let mine: Bool
        var id: UUID { line.id }
    }

    private var entries: [Entry] {
        (engine.theirLines.map { Entry(line: $0, mine: false) } +
         engine.myLines.filter { !$0.source.isEmpty }.map { Entry(line: $0, mine: true) })
            .sorted { $0.line.at < $1.line.at }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 26) {
                    if entries.isEmpty && engine.theirPartial.isEmpty && engine.myPartial.isEmpty {
                        EmptyHint(listening: engine.listening)
                    }
                    ForEach(entries) { entry in
                        Bubble(label: entry.mine ? "Bạn nói" : "Họ nói", source: entry.line.source,
                               target: entry.line.target, mine: entry.mine, unclear: entry.line.unclear)
                            .id(entry.id)
                    }
                    if !engine.theirPartial.isEmpty {
                        PartialLine(text: engine.theirPartial, mine: false).id("theirPartial")
                    }
                    if !engine.myPartial.isEmpty {
                        PartialLine(text: engine.myPartial, mine: true).id("myPartial")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: entries.last?.line.target) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: engine.theirPartial) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: engine.myPartial) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct Bubble: View {
    let label: String
    let source: String
    let target: String
    let mine: Bool
    let unclear: Bool

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(source).font(.system(size: 14)).foregroundStyle(Palette.muted)
            if !target.isEmpty {
                Text(target)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(unclear ? Palette.faint : Palette.text)
            }
        }
        .multilineTextAlignment(mine ? .trailing : .leading)
        .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PartialLine: View {
    let text: String
    let mine: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .italic()
            .foregroundStyle(Palette.faint)
            .multilineTextAlignment(mine ? .trailing : .leading)
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

private struct EmptyHint: View {
    let listening: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(listening ? "Cứ nói đi" : "Chạm \"Bắt đầu nghe\" trước khi nói")
                .font(.system(size: 17, weight: .semibold))
            Text("Người đối diện nói vào board, bạn nghe tiếng Việt qua AirPods. Bạn nói tiếng Việt, họ đọc phụ đề trên board.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 120)
        .padding(.horizontal, 12)
    }
}

/// Board mic · listen / stop · clear
private struct ControlBar: View {
    let engine: ConversationEngine
    @Binding var confirmClear: Bool

    var body: some View {
        HStack {
            Button {
                engine.toggleBoardMic()
            } label: {
                Image(systemName: engine.boardMicOn ? "mic" : "mic.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(engine.boardMicOn ? Palette.text : Palette.muted)
                    .frame(width: 52, height: 52)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(engine.boardMicOn ? Palette.accent : .clear, lineWidth: 2))
            }
            .disabled(engine.board != .ready)
            .accessibilityLabel(engine.boardMicOn ? "Tắt mic của board" : "Bật mic của board")
            Spacer()
            Button {
                if engine.listening { engine.stopConversation() } else { engine.startConversation() }
            } label: {
                // The header already says "Đang nghe": the button says what a tap does
                Label(engine.listening ? "Dừng nghe" : "Bắt đầu nghe",
                      systemImage: engine.listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    .background(engine.listening ? Palette.accent : Palette.surface, in: Capsule())
            }
            .disabled(engine.phase != .running)
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 52, height: 52)
                    .background(Palette.surface, in: Circle())
            }
            .disabled(engine.phase != .running || !engine.hasHistory)
            .accessibilityLabel("Xoá hội thoại")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// Downloads the English ↔ Vietnamese translation models once (system download sheet), then works offline
private struct ModelDownloadView: View {
    let engine: ConversationEngine
    @State private var config: TranslationSession.Configuration?
    @State private var step = 0
    /// The download was cancelled or failed (no network): the button retries the step that failed
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(Palette.accentLight)
            Text("Cần tải mô hình English ↔ Tiếng Việt").font(.system(size: 18, weight: .semibold))
            Text("Tải một lần, sau đó dịch hoàn toàn trên máy: không cần mạng và nhanh hơn.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.muted)
            if failed {
                Text("Chưa tải xong. Kiểm tra mạng rồi thử lại.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.accentLight)
            }
            Button(failed ? "Thử lại" : "Tải mô hình") {
                failed = false
                if config == nil {
                    step = 1
                    config = .init(source: ConversationEngine.english, target: ConversationEngine.vietnamese)
                } else {
                    config?.invalidate()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(step != 0 && !failed)
            Spacer()
        }
        .padding(24)
        .translationTask(config) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                await MainActor.run { failed = true }
                return
            }
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
