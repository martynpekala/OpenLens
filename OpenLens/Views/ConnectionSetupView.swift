import SwiftUI

enum ConnectionSetupStep: Equatable {
    case welcome
    case scanner
    case manual
}

private enum ConnectionSetupSheet: String, Identifiable {
    case tips

    var id: String { rawValue }
}

/// Pairing entry point. The QR lens and the manual form both condense out of the dot field in
/// place, so the whole setup stays on one screen. The caller supplies the manual form's fields and
/// the controls below them, plus any manual-step toolbar items (the tips button hides there).
struct ConnectionWelcomeView<ManualFields: View, ManualAccessories: View>: View {
    @Binding var step: ConnectionSetupStep
    let isCameraActive: Bool
    let canConnectManually: Bool
    let onScanned: (ScannedOpenLensCode) -> Void
    let onConnectManually: () -> Void
    @ViewBuilder let manualFields: ManualFields
    @ViewBuilder let manualAccessories: ManualAccessories

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: ConnectionSetupSheet?
    @State private var scanButtonFrame: CGRect = .zero
    @State private var manualButtonFrame: CGRect = .zero
    @State private var viewfinderFrame: CGRect = .zero
    @State private var manualFieldsFrame: CGRect = .zero
    @State private var fieldPulse: GlowDotField.Pulse?
    @State private var focusChangedAt: Date = .distantPast
    /// Keeps the halo on the last expanded element while it fades out after going back.
    @State private var lastExpandedStep: ConnectionSetupStep = .scanner

    var body: some View {
        ConnectionSetupPage {
            VStack(spacing: 24) {
                switch step {
                case .welcome:
                    VStack(spacing: 24) {
                        ConnectionSetupHeading(
                            systemImage: "macbook.and.iphone",
                            title: AppText.connectionSetupTitle,
                            subtitle: AppText.connectionSetupSubtitle
                        )
                        .padding(.bottom, 8)
                        
                        Text("opencode service start")
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color.appTertiary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Terminal command: opencode service start")

                        Text("opencode pair")
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color.appTertiary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Terminal command: opencode pair")
                    }
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                case .scanner:
                    VStack(spacing: 24) {
                        ConnectionScannerLens(
                            isActive: isCameraActive && presentedSheet == nil,
                            onScanned: onScanned
                        )
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { frame in
                            viewfinderFrame = frame
                        }
                        .accessibilityIdentifier("connection.setup.camera")

                        Text(AppText.connectionScanTitle)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(reduceMotion ? .opacity : AnyTransition(LensMaterializeTransition()))
                case .manual:
                    VStack(spacing: 24) {
                        ConnectionSetupHeading(
                            systemImage: "network",
                            title: AppText.connectionManualTitle,
                            subtitle: ""
                        )

                        VStack(spacing: 16) {
                            VStack(spacing: 0) {
                                manualFields
                            }
                            .background(
                                Color.appTertiary,
                                in: RoundedRectangle(cornerRadius: Self.manualFieldsCornerRadius, style: .continuous)
                            )
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { frame in
                                manualFieldsFrame = frame
                            }
                            .accessibilityIdentifier("connection.setup.manual.fields")

                            manualAccessories
                        }
                    }
                    .transition(reduceMotion ? .opacity : AnyTransition(LensMaterializeTransition()))
                }
            }
        } actions: {
            switch step {
            case .welcome:
                ConnectionSetupButton(title: AppText.connectionPairingScan, action: startScanning)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        scanButtonFrame = frame
                    }
                    .accessibilityIdentifier("connection.setup.scan")
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            case .scanner:
                EmptyView()
            case .manual:
                ConnectionSetupButton(title: AppText.connect, action: onConnectManually)
                    .disabled(!canConnectManually)
                    .accessibilityIdentifier("connection.setup.manual.connect")
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }

            if step != .manual {
                HStack {
                    Text(AppText.connectionSetupV1Prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    ConnectionSetupButton(
                        title: AppText.connectionSetupV1,
                        isPrimary: false,
                        action: showManualForm
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        manualButtonFrame = frame
                    }
                    .accessibilityLabel(AppText.connectionSetupV1AccessibilityLabel)
                    .accessibilityHint(AppText.connectionSetupV1Hint)
                    .accessibilityIdentifier("connection.setup.v1")
                }
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }
        }
        .background {
            GlowDotField(pulse: fieldPulse, focus: fieldFocus)
                .background(Color.appBackground)
                .ignoresSafeArea()
        }
        .toolbar {
            if step != .welcome {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: returnToWelcome) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appPrimary)
                    }
                    .accessibilityLabel(AppText.back)
                    .accessibilityIdentifier("connection.setup.back")
                }
            }

            if step != .manual {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedSheet = .tips
                    } label: {
                        Image(systemName: "questionmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appPrimary)
                    }
                    .accessibilityLabel(AppText.connectionSetupTips)
                    .accessibilityIdentifier("connection.setup.tips")
                }
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: fieldPulse)
        .onChange(of: step) { _, newStep in
            focusChangedAt = .now
            if newStep != .welcome {
                lastExpandedStep = newStep
            }
        }
        .sheet(item: $presentedSheet) { _ in
            ConnectionSetupTipsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.appBackground)
        }
    }

    private static var manualFieldsCornerRadius: CGFloat { 20 }

    /// Dots gather just outside the lens outline or the manual fields while either is open.
    private var fieldFocus: GlowDotField.Focus? {
        let focusedStep = step == .welcome ? lastExpandedStep : step
        let rect: CGRect
        let cornerRadius: CGFloat
        switch focusedStep {
        case .welcome:
            return nil
        case .scanner:
            let inset = ConnectionScannerLens.outlineInset + 4
            rect = viewfinderFrame.insetBy(dx: -inset, dy: -inset)
            cornerRadius = ConnectionScannerLens.cornerRadius + inset
        case .manual:
            let inset: CGFloat = 6
            rect = manualFieldsFrame.insetBy(dx: -inset, dy: -inset)
            cornerRadius = Self.manualFieldsCornerRadius + inset
        }
        guard !rect.isEmpty else { return nil }
        return GlowDotField.Focus(
            rect: rect,
            cornerRadius: cornerRadius,
            isActive: step != .welcome,
            date: focusChangedAt
        )
    }

    private func startScanning() {
        expand(to: .scanner, from: scanButtonFrame)
    }

    private func showManualForm() {
        expand(to: .manual, from: manualButtonFrame)
    }

    /// Sends a ripple out from the tapped button, then condenses the next step out of the field.
    private func expand(to newStep: ConnectionSetupStep, from buttonFrame: CGRect) {
        fieldPulse = GlowDotField.Pulse(
            origin: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY),
            date: .now
        )
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.75, bounce: 0.2)) {
            step = newStep
        }
    }

    /// Collapses the lens or form back into the field, releasing a ripple from where it sat.
    private func returnToWelcome() {
        let expandedFrame = step == .manual ? manualFieldsFrame : viewfinderFrame
        if expandedFrame != .zero {
            fieldPulse = GlowDotField.Pulse(
                origin: CGPoint(x: expandedFrame.midX, y: expandedFrame.midY),
                date: .now
            )
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.15)) {
            step = .welcome
        }
    }
}

/// QR camera that reveals itself with a light sweep and an outline drawn in from the top.
private struct ConnectionScannerLens: View {
    static let size: CGFloat = 260
    static let cornerRadius: CGFloat = 30
    static let outlineInset: CGFloat = 5

    let isActive: Bool
    let onScanned: (ScannedOpenLensCode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beamProgress: CGFloat = 0
    @State private var outlineProgress: Double = 0
    @State private var outlineGlow: Double = 1

    var body: some View {
        QRCodeCameraView(isActive: isActive, onScanned: onScanned)
            .frame(width: Self.size, height: Self.size)
            .overlay(alignment: .top) {
                if !reduceMotion {
                    beam
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay { outline }
            .onAppear(perform: playReveal)
    }

    private var beam: some View {
        LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.18), .white.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 72)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white)
                .frame(height: 1.5)
                .shadow(color: .white, radius: 6)
        }
        .offset(y: -72 + beamProgress * (Self.size + 72))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var outline: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius + Self.outlineInset, style: .continuous)
        return ZStack {
            shape
                .stroke(Color.appPrimary.opacity(0.8), lineWidth: 3)
                .blur(radius: 6)
                .opacity(outlineGlow)
            shape
                .stroke(Color.appPrimary.opacity(0.35), lineWidth: 1)
        }
        .padding(-Self.outlineInset)
        .mask {
            SweepWedge(progress: outlineProgress)
                .padding(-24)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func playReveal() {
        guard !reduceMotion else {
            outlineProgress = 1
            outlineGlow = 0.3
            return
        }
        withAnimation(.easeInOut(duration: 0.9).delay(0.2)) {
            outlineProgress = 1
        }
        withAnimation(.easeInOut(duration: 1.1).delay(0.3)) {
            beamProgress = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.6)) {
                outlineGlow = 0.3
            }
        }
    }
}

/// Scales the lens up out of a blur, as if it condenses from the dot field.
private struct LensMaterializeTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.6)
            .blur(radius: phase.isIdentity ? 0 : 20)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// Pie wedge centered on the top edge that opens symmetrically to a full circle.
private struct SweepWedge: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let halfSweep = Angle.degrees(180 * min(max(progress, 0), 1))
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: hypot(rect.width, rect.height),
            startAngle: .degrees(-90) - halfSweep,
            endAngle: .degrees(-90) + halfSweep,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct ConnectionSetupTipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ConnectionSetupDetail(
                        systemImage: "wifi",
                        title: AppText.connectionSetupNetworkTitle,
                        text: AppText.connectionSetupNetworkDetail
                    )
                    ConnectionSetupDetail(
                        systemImage: "network",
                        title: AppText.connectionSetupHostnameTitle,
                        text: AppText.connectionSetupHostnameDetail
                    )
                    ConnectionSetupDetail(
                        systemImage: "qrcode",
                        title: AppText.connectionSetupPairingTitle,
                        text: AppText.connectionPairingHint
                    )
                }
                .padding(28)
                .frame(maxWidth: 440, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.appBackground)
            .navigationTitle(AppText.connectionSetupTips)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("connection.setup.tips.done")
                }
            }
        }
    }
}

private struct ConnectionSetupPage<Content: View, Actions: View>: View {
    private let content: Content
    private let actions: Actions

    init(@ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    content
                        .frame(maxWidth: 340)
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                actions
            }
                .frame(maxWidth: 340)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .background {
                    LinearGradient(
                        colors: [Color.appBackground.opacity(0), Color.appBackground.opacity(0.7)],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.45)
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectionSetupHeading: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Color.appSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }
}

private struct ConnectionSetupDetail: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 21))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConnectionSetupButton: View {
    let title: String
    var isPrimary = true
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, minHeight: 20)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(backgroundColor, in: Capsule())
                .overlay {
                    if !isPrimary {
                        Capsule().stroke(Color.appSeparator, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if !isEnabled { return Color.appSecondary.opacity(0.6) }
        return isPrimary ? Color.appOnAccent : Color.appPrimary
    }

    private var backgroundColor: Color {
        if !isEnabled { return Color.appTertiary }
        return isPrimary ? Color.appAccent : Color.clear
    }
}

#Preview("Connect to your computer") {
    ConnectionWelcomePreview(step: .welcome)
}

#Preview("Scan on the connection screen") {
    ConnectionWelcomePreview(step: .scanner)
}

#Preview("Manual connection") {
    ConnectionWelcomePreview(step: .manual)
}

private struct ConnectionWelcomePreview: View {
    @State var step: ConnectionSetupStep
    @State private var serverURL = ""

    var body: some View {
        NavigationStack {
            ConnectionWelcomeView(
                step: $step,
                isCameraActive: false,
                canConnectManually: !serverURL.isEmpty,
                onScanned: { _ in },
                onConnectManually: {}
            ) {
                TextField("192.168.1.50:4096", text: $serverURL)
                    .font(.system(size: 15, design: .monospaced))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
            } manualAccessories: {
                EmptyView()
            }
        }
    }
}

#Preview("Connection tips") {
    ConnectionSetupTipsView()
}
