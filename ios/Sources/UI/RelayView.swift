import AVFoundation
import ClaudeRelay
import Observation
import SwiftUI

@MainActor
@Observable
final class RelayModel {
    private(set) var status: ClaudeRelayService.Status = .notPaired
    private(set) var host: String?
    @ObservationIgnored private let service: ClaudeRelayService

    init(link: ESPLink) {
        service = ClaudeRelayService(link: link)
        service.onStatus = { [weak self] status, host in
            Task { @MainActor in
                self?.status = status
                self?.host = host
            }
        }
    }

    var paired: Bool { host != nil }

    var statusText: String {
        switch status {
        case .notPaired: "Not paired with a Mac"
        case .waitingForBoard: "Paired with \(host ?? "your Mac"). Waiting for the board"
        case .connecting: "Connecting to \(host ?? "your Mac") over Tailscale…"
        case .relayReady: "Relay ready: the board reaches \(host ?? "your Mac") through this iPhone when the Mac is out of range"
        case .failed(let why): "Not connected: \(why)"
        }
    }

    func pair(_ p: RelayPairing) { service.pair(p) }
    func forget() { service.forget() }
}

struct RelayView: View {
    let model: RelayModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") { Text(model.statusText) }
                Section {
                    Button(model.paired ? "Pair again" : "Pair with Mac", systemImage: "qrcode.viewfinder") { scanning = true }
                    if model.paired {
                        Button("Forget this Mac", systemImage: "trash", role: .destructive) { model.forget() }
                    }
                } footer: {
                    Text("""
                    On the Mac, run mac/install.sh (or ~/.claude-board/bin/claude-board --pair) and scan the QR code \
                    it prints. Both devices need Tailscale on the same tailnet. Requests are never answered here: \
                    the iPhone only passes them between the board and the Mac.
                    """)
                }
            }
            .navigationTitle("Claude relay")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScannerView { code in
                    scanning = false
                    if let p = RelayPairing.parse(code) {
                        model.pair(p)
                    } else {
                        scanError = "That is not a claude-board pairing code for a Tailscale address."
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Can't pair", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
                Button("OK") { scanError = nil }
            } message: {
                Text(scanError ?? "")
            }
        }
    }
}

/// Camera QR scanner (AVFoundation); calls `found` once with the first QR code's text
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.configure() : self.showDenied() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.layer.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        private func showDenied() {
            let label = UILabel()
            label.text = "Allow the camera for Live Translator in Settings to scan the pairing code."
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 24, dy: 24)
            view.addSubview(label)
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            session.stopRunning()
            found?(code)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }
    }
}
