import SwiftUI
import AVFoundation

/// Native QR code scanner using AVFoundation camera capture.
/// Parses scanned codes as `openlens://connect` deep links.
struct QRScannerView: View {
    var onScanned: (DeepLinkConnection) -> Void
    var onDismiss: () -> Void

    @State private var errorMessage: String?
    @State private var hasScanned = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(onCodeFound: handleCode)
                .ignoresSafeArea()

            // Overlay UI
            VStack {
                // Top bar
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                // Viewfinder frame
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 260, height: 260)

                Spacer()

                // Instructions
                VStack(spacing: 8) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(AppText.qrInstruction)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(AppText.qrInstructionSubtitle)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 60)
            }
        }
    }

    private func handleCode(_ code: String) {
        guard !hasScanned else { return }

        guard let url = URL(string: code),
              let deepLink = DeepLinkConnection(from: url) else {
            errorMessage = AppText.qrInvalid
            // Reset after a moment so user can try again
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                errorMessage = nil
            }
            return
        }

        hasScanned = true
        onScanned(deepLink)
    }
}

// MARK: - AVFoundation Camera Preview

private struct CameraPreview: UIViewRepresentable {
    let onCodeFound: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return view
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return view }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)

        context.coordinator.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.session?.stopRunning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeFound: onCodeFound)
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var session: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
        let onCodeFound: (String) -> Void

        init(onCodeFound: @escaping (String) -> Void) {
            self.onCodeFound = onCodeFound
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            onCodeFound(value)
        }
    }
}
