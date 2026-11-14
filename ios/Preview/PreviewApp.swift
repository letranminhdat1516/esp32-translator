// Phone preview: the real ContentView in an iPhone-sized window, with a panel that fakes the controller (UIState).
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

@MainActor
private func previewState(demo: Bool) -> UIState {
    let ui = UIState.sampleChoosing()
    ui.session = .running("en")
    ui.languageLabel = "English"
    ui.board = .ready
    // Intents as the controller binds them, enough to click through the screen
    ui.startStop = { ui.listening.toggle() }
    ui.toggleBoardMic = { ui.boardMicOn.toggle() }
    ui.clear = {
        ui.lines.removeAll()
        ui.theirPartial = ""
        ui.myPartial = ""
    }
    ui.pickLanguage = { code in
        ui.languageCode = code
        ui.languageLabel = ui.languageNames[code] ?? code
    }
    guard demo else { return ui }
    // --demo: start with a whole conversation on screen (both sides, an unclear line, both partials)
    for (i, s) in sampleTheirs.enumerated() {
        ui.lines.append(UILine(id: "t\(i)", mine: false, source: s.0, target: s.1,
                               at: Date(timeIntervalSinceNow: Double(i * 2 - 10))))
        let m = sampleMine[i]
        ui.lines.append(UILine(id: "m\(i)", mine: true, source: m.0, target: m.1,
                               at: Date(timeIntervalSinceNow: Double(i * 2 - 9))))
    }
    ui.lines.append(UILine(id: "u", mine: false, source: "…the uh… later maybe…", target: "Không nghe rõ",
                           unclear: true, at: Date()))
    ui.theirPartial = "So the bus leaves from"
    ui.myPartial = "Cho mình hỏi đường ra"
    ui.listening = true
    return ui
}

@main
struct PhonePreviewApp: App {
    @State private var ui = previewState(demo: CommandLine.arguments.contains("--demo"))

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate() }
    }

    var body: some Scene {
        WindowGroup("Live Translator · iPhone preview") {
            HStack(spacing: 0) {
                ContentView(ui: ui)
                    .frame(width: 393, height: 852)
                    .clipShape(RoundedRectangle(cornerRadius: 44))
                    .padding(16)
                    .background(Color(white: 0.12))
                Controls(ui: ui)
                    .frame(width: 240)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct Controls: View {
    @Bindable var ui: UIState
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
                    Text("Chọn ngôn ngữ").tag(4)
                }
                Picker("Board", selection: $ui.board) {
                    Text("Bluetooth tắt").tag(BoardState.off)
                    Text("Đang tìm").tag(BoardState.scanning)
                    Text("Đang kết nối").tag(BoardState.connecting)
                    Text("Đã kết nối").tag(BoardState.ready)
                }
                Toggle("Mic board", isOn: $ui.boardMicOn)
                Toggle("Đang nghe", isOn: $ui.listening)
                Toggle("Thiếu giọng đọc", isOn: $ui.ttsVoiceMissing)
            }
            Section("Hội thoại") {
                Button("+ Họ nói") {
                    let s = sampleTheirs[their % sampleTheirs.count]
                    their += 1
                    ui.lines.append(UILine(id: "t-\(their)", mine: false, source: s.0, target: s.1, at: Date()))
                }
                Button("+ Bạn nói") {
                    let s = sampleMine[mine % sampleMine.count]
                    mine += 1
                    ui.lines.append(UILine(id: "m-\(mine)", mine: true, source: s.0, target: s.1, at: Date()))
                }
                Button("+ Câu nghe không rõ") {
                    ui.lines.append(UILine(id: "u-\(UUID().uuidString)", mine: false,
                                           source: "…the uh… later maybe…", target: "Không nghe rõ",
                                           unclear: true, at: Date()))
                }
                Toggle("Họ đang nói dở", isOn: partial(\.theirPartial, "So the bus leaves from"))
                Toggle("Bạn đang nói dở", isOn: partial(\.myPartial, "Cho mình hỏi đường ra"))
                Button("Xoá hết") { ui.clear() }
            }
        }
        .formStyle(.grouped)
    }

    private var phaseBinding: Binding<Int> {
        Binding {
            switch ui.session {
            case .running?: 0
            case .needsDownload?: 1
            case .failed?: 3
            case .choosing?: 4
            default: 2
            }
        } set: {
            ui.session = [.running("en"), .needsDownload("ja", missing: UIState.sampleMissing), .preparing("en"),
                          .failed("en", reason: "recognizer stopped"), .choosing()][$0]
        }
    }

    private func partial(_ key: ReferenceWritableKeyPath<UIState, String>, _ text: String) -> Binding<Bool> {
        Binding { !ui[keyPath: key].isEmpty } set: { ui[keyPath: key] = $0 ? text : "" }
    }
}
