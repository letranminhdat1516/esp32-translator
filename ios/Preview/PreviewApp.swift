// Phone preview: the real ContentView in an iPhone-sized window, with a panel that fakes the engine.
// Build and run: ios/Preview/run.sh
import AppKit
import SwiftUI

private let sampleTheirs: [(String, String)] = [
    ("Hi! Are you ready to order?", "Chào bạn! Bạn gọi món chưa?"),
    ("The pho comes with extra herbs on the side.", "Phở có thêm rau thơm để riêng."),
    ("Mr. Nguyen, your table is ready.", "Anh Nguyễn, bàn của anh đã sẵn sàng."),
]
private let sampleMine: [(String, String)] = [
    ("Cho mình một tô phở bò tái nhé.", "One rare beef pho, please."),
    ("Ở đây có wifi không bạn?", "Do you have wifi here?"),
    ("Tính tiền giúp mình.", "Could I have the bill, please?"),
]

@main
struct PhonePreviewApp: App {
    @State private var engine = ConversationEngine()
    private let relay = RelayModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate() }
    }

    var body: some Scene {
        WindowGroup("Live Translator · iPhone preview") {
            HStack(spacing: 0) {
                ContentView(engine: engine, relay: relay)
                    .frame(width: 393, height: 852)
                    .clipShape(RoundedRectangle(cornerRadius: 44))
                    .padding(16)
                    .background(Color(white: 0.12))
                Controls(engine: engine)
                    .frame(width: 240)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct Controls: View {
    @Bindable var engine: ConversationEngine
    @State private var their = 0
    @State private var mine = 0

    var body: some View {
        Form {
            Section("Màn hình") {
                Picker("Phase", selection: phaseBinding) {
                    Text("Đang dịch").tag(0)
                    Text("Cần tải mô hình").tag(1)
                    Text("Đang chuẩn bị").tag(2)
                    Text("Lỗi").tag(3)
                }
                Picker("Board", selection: $engine.board) {
                    Text("Bluetooth tắt").tag(ESPLink.State.off)
                    Text("Đang tìm").tag(ESPLink.State.scanning)
                    Text("Đang kết nối").tag(ESPLink.State.connecting)
                    Text("Đã kết nối").tag(ESPLink.State.ready)
                }
                Toggle("Mic board", isOn: $engine.boardMicOn)
                Toggle("Đang nghe", isOn: $engine.listening)
            }
            Section("Hội thoại") {
                Button("+ Họ nói") {
                    let s = sampleTheirs[their % sampleTheirs.count]
                    their += 1
                    engine.theirLines.append(.init(source: s.0, target: s.1))
                }
                Button("+ Bạn nói") {
                    let s = sampleMine[mine % sampleMine.count]
                    mine += 1
                    engine.myLines.append(.init(source: s.0, target: s.1, turn: mine))
                }
                Button("+ Câu nghe không rõ") {
                    engine.theirLines.append(.init(source: "…the uh… later maybe…", target: "", unclear: true))
                }
                Toggle("Họ đang nói dở", isOn: partial(\.theirPartial, "So the bus leaves from"))
                Toggle("Bạn đang nói dở", isOn: partial(\.myPartial, "Cho mình hỏi đường ra"))
                Button("Xoá hết") { engine.clearHistory() }
            }
        }
        .formStyle(.grouped)
    }

    private var phaseBinding: Binding<Int> {
        Binding {
            switch engine.phase {
            case .running, .idle: 0
            case .needsTranslationModels: 1
            case .preparing: 2
            case .failed: 3
            }
        } set: {
            engine.phase = [.running, .needsTranslationModels, .preparing("Đang tải mô hình giọng nói…"),
                            .failed("Không tìm thấy mô hình nhận dạng tiếng Việt.")][$0]
        }
    }

    private func partial(_ key: ReferenceWritableKeyPath<ConversationEngine, String>, _ text: String) -> Binding<Bool> {
        Binding { !engine[keyPath: key].isEmpty } set: { engine[keyPath: key] = $0 ? text : "" }
    }
}
