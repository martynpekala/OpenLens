import SwiftUI

/// Native QR code scanner using AVFoundation camera capture.
/// Parses direct LAN and native OpenCode pairing codes.
enum ScannedOpenLensCode {
    case direct(DeepLinkConnection)
    case openCodePairing(OpenCodePairingLink)

    init?(url: URL) {
        if let link = OpenCodePairingLink(url: url) {
            self = .openCodePairing(link)
        } else if let connection = DeepLinkConnection(from: url) {
            self = .direct(connection)
        } else {
            return nil
        }
    }
}

struct QRScannerView: View {
    var onScanned: (ScannedOpenLensCode) -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            QRCodeCameraView(
                isActive: true,
                showsViewfinder: false,
                usesDarkBackground: true,
                onScanned: onScanned
            )
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
                    Text(AppText.qrInstruction)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(AppText.qrInstructionSubtitle)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 60)
            }
        }
    }
}
