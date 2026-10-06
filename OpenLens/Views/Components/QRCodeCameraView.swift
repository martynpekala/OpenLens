import SwiftUI
import AVFoundation

/// Shared scanner surface for guided pairing and the manual screen's full-screen scanner.
struct QRCodeCameraView: View {
    private enum CameraAccess {
        case checking
        case authorized
        case denied
        case unavailable
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    let isActive: Bool
    var showsViewfinder = true
    var usesDarkBackground = false
    let onScanned: (ScannedOpenLensCode) -> Void

    @State private var cameraAccess: CameraAccess = .checking
    @State private var errorMessage: String?
    @State private var hasScanned = false

    private var cameraIsActive: Bool {
        isActive && scenePhase == .active
    }

    var body: some View {
        ZStack {
            usesDarkBackground ? Color.black : Color.appTertiary

            if cameraAccess == .authorized {
                Color.black
                if cameraIsActive {
                    CameraPreview(onCodeFound: handleCode)
                }

                if showsViewfinder {
                    QRViewfinderCorners()
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .padding(22)
                        .accessibilityHidden(true)
                }
            } else {
                cameraStatus
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                }
            }
        }
        .task(id: cameraIsActive) {
            guard cameraIsActive else { return }
            hasScanned = false
            await updateCameraAccess()
        }
        .task(id: errorMessage) {
            guard errorMessage != nil else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                errorMessage = nil
            } catch {
                // The screen disappeared or a newer error replaced this one.
            }
        }
    }

    @ViewBuilder
    private var cameraStatus: some View {
        if cameraAccess == .checking {
            ProgressView()
                .tint(usesDarkBackground ? .white : Color.appPrimary)
        } else {
            VStack(spacing: 12) {
                Image(systemName: cameraAccess == .denied ? "camera.fill" : "camera")
                    .font(.system(size: 28))
                    .accessibilityHidden(true)

                Text(cameraAccess == .denied ? AppText.cameraAccessTitle : AppText.cameraUnavailableTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text(cameraAccess == .denied ? AppText.cameraAccessBody : AppText.cameraUnavailableBody)
                    .font(.system(size: 12))
                    .foregroundStyle(usesDarkBackground ? .white.opacity(0.7) : Color.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if cameraAccess == .denied {
                    Button(AppText.openSettings, action: openCameraSettings)
                        .font(.system(size: 13, weight: .semibold))
                        .tint(usesDarkBackground ? .white : Color.appPrimary)
                }
            }
            .foregroundStyle(usesDarkBackground ? .white : Color.appPrimary)
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }

    private func updateCameraAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccess = AVCaptureDevice.default(for: .video) == nil ? .unavailable : .authorized
        case .notDetermined:
            guard AVCaptureDevice.default(for: .video) != nil else {
                cameraAccess = .unavailable
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            cameraAccess = granted ? .authorized : .denied
        case .denied, .restricted:
            cameraAccess = .denied
        @unknown default:
            cameraAccess = .unavailable
        }
    }

    private func openCameraSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func handleCode(_ code: String) {
        guard isActive && scenePhase == .active else { return }
        guard !hasScanned else { return }

        guard let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scannedCode = ScannedOpenLensCode(url: url) else {
            errorMessage = AppText.qrInvalid
            return
        }

        hasScanned = true
        onScanned(scannedCode)
    }
}

private struct QRViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 24
        var path = Path()
        for (corner, xDirection, yDirection) in [
            (CGPoint(x: rect.minX, y: rect.minY), CGFloat(1), CGFloat(1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGFloat(-1), CGFloat(1)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGFloat(1), CGFloat(-1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGFloat(-1), CGFloat(-1))
        ] {
            path.move(to: CGPoint(x: corner.x + length * xDirection, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + length * yDirection))
        }
        return path
    }
}

// MARK: - AVFoundation Camera Preview

private struct CameraPreview: UIViewRepresentable {
    let onCodeFound: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PreviewContainerView(frame: .zero)
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
        view.setPreviewLayer(previewLayer)

        context.coordinator.previewLayer = previewLayer

        context.coordinator.captureQueue.async {
            session.startRunning()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? PreviewContainerView)?.updatePreviewLayerFrame()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        let session = coordinator.session
        coordinator.captureQueue.async {
            session?.stopRunning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeFound: onCodeFound)
    }

    private final class PreviewContainerView: UIView {
        private weak var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            updatePreviewLayerFrame()
        }

        func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
            previewLayer?.removeFromSuperlayer()
            previewLayer = layer
            self.layer.addSublayer(layer)
            updatePreviewLayerFrame()
        }

        func updatePreviewLayerFrame() {
            previewLayer?.frame = bounds
        }
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let captureQueue = DispatchQueue(label: "app.openlens.qr-camera", qos: .userInitiated)
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
