import SwiftUI

enum ConnectionSetupStep: Equatable {
    case welcome
    case scanner
    case manual
}

/// A connection attempt, shown in place of the setup step it started from.
struct ConnectionSetupStatus: Equatable {
    enum Phase: Equatable {
        /// Trading a scanned pairing code for credentials.
        case pairing
        case connecting
        case reconnecting
        /// Stays up until the app swaps in its main interface.
        case connected
        case failed(title: String, message: String, needsLocalNetworkAccess: Bool)

        var isInFlight: Bool {
            switch self {
            case .pairing, .connecting, .reconnecting: true
            case .connected, .failed: false
            }
        }
    }

    var phase: Phase
    /// Host and port shown under the title.
    var serverName: String?
}

private enum ConnectionSetupSheet: String, Identifiable {
    case tips
    /// The manual form's version of the tips: just how each OpenCode version listens on the network.
    case manualTips

    var id: String { rawValue }
}

/// Elements the dot field's halo can wrap.
private enum ConnectionSetupHaloTarget {
    case lens
    case manualFields
    case orb
}

private struct ConnectionSetupHaloOutline: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat
}

/// Pairing entry point. The QR lens and the manual form both condense out of the dot field in
/// place, so the whole setup stays on one screen. Connection attempts play out there too: the open
/// step condenses into a status orb that the dots circle while OpenLens waits on the network. The
/// caller supplies the manual form's fields and the controls below them.
struct ConnectionWelcomeView<ManualFields: View, ManualAccessories: View>: View {
    @Binding var step: ConnectionSetupStep
    /// The attempt in progress; the step it started from comes back once it clears.
    let status: ConnectionSetupStatus?
    let isCameraActive: Bool
    let canConnectManually: Bool
    let onScanned: (ScannedOpenLensCode) -> Void
    let onConnectManually: () -> Void
    let onRetry: () -> Void
    /// Stops the attempt and clears the status.
    let onCancel: () -> Void
    let onOpenSettings: () -> Void
    @ViewBuilder let manualFields: ManualFields
    @ViewBuilder let manualAccessories: ManualAccessories

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: ConnectionSetupSheet?
    @State private var scanButtonFrame: CGRect = .zero
    @State private var manualButtonFrame: CGRect = .zero
    @State private var viewfinderFrame: CGRect = .zero
    @State private var manualFieldsFrame: CGRect = .zero
    @State private var orbFrame: CGRect = .zero
    @State private var fieldPulse: GlowDotField.Pulse?
    @State private var focusChangedAt: Date = .distantPast
    /// Keeps the halo on the last focused element while it fades out after going back.
    @State private var lastFocusedElement: ConnectionSetupHaloTarget = .lens
    /// Where the halo sat before the focus moved, held until the new element has been measured.
    @State private var haloFallback: ConnectionSetupHaloOutline?

    var body: some View {
        ConnectionSetupPage {
            VStack(spacing: 24) {
                if let status {
                    statusContent(status)
                        .transition(reduceMotion ? .opacity : AnyTransition(LensMaterializeTransition()))
                } else {
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
                                onScanned: handleScan
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
            }
        } actions: {
            if let status {
                statusActions(status)
            } else {
                switch step {
                case .welcome:
                    ConnectionSetupButton(title: AppText.connectionPairingScan, action: startScanning)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { frame in
                            scanButtonFrame = frame
                        }
                        .accessibilityIdentifier("connection.setup.scan")
                        .transition(actionTransition)
                case .scanner:
                    EmptyView()
                case .manual:
                    ConnectionSetupButton(title: AppText.connect, action: onConnectManually)
                        .disabled(!canConnectManually)
                        .accessibilityIdentifier("connection.setup.manual.connect")
                        .transition(actionTransition)
                }

                if step != .manual {


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
                    
                    .transition(actionTransition)
                }
            }
        }
        .animation(statusAnimation, value: status)
        .background {
            GlowDotField(pulse: fieldPulse, focus: fieldFocus)
                .background(Color.appBackground)
                .ignoresSafeArea()
        }
        .toolbar {
            if step != .welcome && status == nil {
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

            if showsTipsButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedSheet = step == .manual ? .manualTips : .tips
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
        .sensoryFeedback(trigger: fieldPulse) { _, _ in
            // Arriving gets a success tap of its own instead.
            status?.phase == .connected ? nil : .impact(flexibility: .soft)
        }
        .sensoryFeedback(trigger: status?.phase) { oldPhase, newPhase in
            switch newPhase {
            case .connected?:
                // Reconnecting on its own lands quietly; attempts the user started get a success tap.
                return oldPhase == .reconnecting ? nil : .success
            case .failed?:
                return .error
            default:
                return nil
            }
        }
        .onChange(of: focusedElement) { oldElement, newElement in
            // The halo ramps in or out when it gathers or releases, and glides between elements.
            if (oldElement == nil) != (newElement == nil) {
                focusChangedAt = .now
            }
            if let newElement {
                haloFallback = oldElement.flatMap { haloOutline(for: $0) }
                lastFocusedElement = newElement
            }
        }
        .onChange(of: status?.phase) { _, newPhase in
            statusPhaseChanged(to: newPhase)
        }
        .sheet(item: $presentedSheet) { sheet in
            ConnectionSetupTipsView(sheet: sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.appBackground)
        }
    }

    private static var manualFieldsCornerRadius: CGFloat { 20 }

    private var statusAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.75, bounce: 0.2)
    }

    private var actionTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    /// Tips stay out of the way of an attempt still in progress.
    private var showsTipsButton: Bool {
        guard let status else { return true }
        if case .failed = status.phase { return true }
        return false
    }

    /// Leaves a failed attempt for the step it started from.
    private var statusDismissTitle: String {
        switch step {
        case .welcome: AppText.cancel
        case .scanner: AppText.connectionScanAgain
        case .manual: AppText.connectionEditDetails
        }
    }

    private func statusContent(_ status: ConnectionSetupStatus) -> some View {
        VStack(spacing: 28) {
            ConnectionStatusOrb(phase: status.phase)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    orbFrame = frame
                }
                .accessibilityHidden(true)

            // Room for the longest copy keeps the orb from bobbing between phases.
            ConnectionStatusCaption(status: status)
                .frame(minHeight: 150, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.setup.status")
    }

    @ViewBuilder
    private func statusActions(_ status: ConnectionSetupStatus) -> some View {
        switch status.phase {
        case .pairing, .connecting, .reconnecting, .connected:
            // Once connected the button fades but keeps its place, so the orb holds still until
            // the app takes over.
            let isConnected = status.phase == .connected
            ConnectionSetupButton(title: AppText.cancel, isPrimary: false, action: cancelAttempt)
                .opacity(isConnected ? 0 : 1)
                .allowsHitTesting(!isConnected)
                .accessibilityHidden(isConnected)
                .accessibilityIdentifier("connection.setup.status.cancel")
                .transition(actionTransition)
        case .failed(_, _, let needsLocalNetworkAccess):
            if needsLocalNetworkAccess {
                ConnectionSetupButton(title: AppText.openSettings, action: onOpenSettings)
                    .accessibilityIdentifier("connection.setup.status.settings")
                    .transition(actionTransition)
            }

            ConnectionSetupButton(title: AppText.tryAgain, isPrimary: !needsLocalNetworkAccess, action: retryAttempt)
                .accessibilityIdentifier("connection.setup.status.retry")
                .transition(actionTransition)

            ConnectionSetupButton(title: statusDismissTitle, isPrimary: false, action: cancelAttempt)
                .accessibilityIdentifier("connection.setup.status.dismiss")
                .transition(actionTransition)
        }
    }

    /// What the halo wraps: the status orb during an attempt, otherwise the open step's element.
    private var focusedElement: ConnectionSetupHaloTarget? {
        if status != nil { return .orb }
        switch step {
        case .welcome: return nil
        case .scanner: return .lens
        case .manual: return .manualFields
        }
    }

    /// Dots gather just outside the lens outline, the manual fields, or the status orb, and circle
    /// the orb while an attempt is in flight.
    private var fieldFocus: GlowDotField.Focus? {
        guard let outline = haloOutline(for: focusedElement ?? lastFocusedElement) ?? haloFallback else {
            return nil
        }
        return GlowDotField.Focus(
            rect: outline.rect,
            cornerRadius: outline.cornerRadius,
            isActive: focusedElement != nil,
            date: focusChangedAt,
            isOrbiting: status?.phase.isInFlight == true
        )
    }

    /// The halo's outline around an element, or nil until the element has been measured.
    private func haloOutline(for element: ConnectionSetupHaloTarget) -> ConnectionSetupHaloOutline? {
        switch element {
        case .lens:
            guard !viewfinderFrame.isEmpty else { return nil }
            let inset = ConnectionScannerLens.outlineInset + 4
            return ConnectionSetupHaloOutline(
                rect: viewfinderFrame.insetBy(dx: -inset, dy: -inset),
                cornerRadius: ConnectionScannerLens.cornerRadius + inset
            )
        case .manualFields:
            guard !manualFieldsFrame.isEmpty else { return nil }
            let inset: CGFloat = 6
            return ConnectionSetupHaloOutline(
                rect: manualFieldsFrame.insetBy(dx: -inset, dy: -inset),
                cornerRadius: Self.manualFieldsCornerRadius + inset
            )
        case .orb:
            guard !orbFrame.isEmpty else { return nil }
            let inset = ConnectionStatusOrb.outlineInset + 4
            let rect = orbFrame.insetBy(dx: -inset, dy: -inset)
            return ConnectionSetupHaloOutline(rect: rect, cornerRadius: rect.width / 2)
        }
    }

    private func startScanning() {
        expand(to: .scanner, from: scanButtonFrame)
    }

    private func showManualForm() {
        expand(to: .manual, from: manualButtonFrame)
    }

    /// Sends a ripple out from the tapped button, then condenses the next step out of the field.
    private func expand(to newStep: ConnectionSetupStep, from buttonFrame: CGRect) {
        sendPulse(from: buttonFrame)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.75, bounce: 0.2)) {
            step = newStep
        }
    }

    /// Collapses the lens or form back into the field, releasing a ripple from where it sat.
    private func returnToWelcome() {
        sendPulse(from: step == .manual ? manualFieldsFrame : viewfinderFrame)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.15)) {
            step = .welcome
        }
    }

    /// A scan ripples out of the lens as it condenses into the status orb.
    private func handleScan(_ code: ScannedOpenLensCode) {
        sendPulse(from: viewfinderFrame)
        onScanned(code)
    }

    private func retryAttempt() {
        sendPulse(from: orbFrame)
        onRetry()
    }

    private func cancelAttempt() {
        sendPulse(from: orbFrame)
        onCancel()
    }

    /// Ripples out of the orb as the connection lands, and reads the outcome out for VoiceOver.
    private func statusPhaseChanged(to phase: ConnectionSetupStatus.Phase?) {
        switch phase {
        case .connected?:
            sendPulse(from: orbFrame)
            AccessibilityNotification.Announcement(AppText.connected).post()
        case .failed(let title, _, _)?:
            AccessibilityNotification.Announcement(title).post()
        default:
            break
        }
    }

    private func sendPulse(from frame: CGRect) {
        guard frame != .zero else { return }
        fieldPulse = GlowDotField.Pulse(origin: CGPoint(x: frame.midX, y: frame.midY), date: .now)
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

/// The open step condensed into a disc that carries the attempt: it breathes while OpenLens waits
/// on the network, flashes when the connection lands, and shakes off a failure.
private struct ConnectionStatusOrb: View {
    static let size: CGFloat = 132
    static let outlineInset: CGFloat = 5

    let phase: ConnectionSetupStatus.Phase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var outlineProgress: Double = 0
    @State private var outlineGlow: Double = 1
    @State private var shakeCount = 0

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(Color.appPrimary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.breathe, isActive: phase.isInFlight && !reduceMotion)
            .frame(width: Self.size, height: Self.size)
            .background(Color.appTertiary.opacity(0.7), in: Circle())
            .overlay { outline }
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: shakeCount) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-10, duration: 0.07)
                    CubicKeyframe(8, duration: 0.09)
                    CubicKeyframe(-5, duration: 0.09)
                    CubicKeyframe(2, duration: 0.08)
                    CubicKeyframe(0, duration: 0.1)
                }
            }
            .onAppear(perform: playReveal)
            .onChange(of: phase) { _, newPhase in
                switch newPhase {
                case .connected:
                    flashOutline()
                case .failed:
                    if !reduceMotion {
                        shakeCount += 1
                    }
                default:
                    break
                }
            }
    }

    private var symbolName: String {
        switch phase {
        case .pairing, .connecting, .reconnecting:
            "macbook.and.iphone"
        case .connected:
            "checkmark"
        case .failed(_, _, let needsLocalNetworkAccess):
            needsLocalNetworkAccess ? "wifi.exclamationmark" : "exclamationmark"
        }
    }

    private var outline: some View {
        ZStack {
            Circle()
                .stroke(Color.appPrimary.opacity(0.8), lineWidth: 3)
                .blur(radius: 6)
                .opacity(outlineGlow)
            Circle()
                .stroke(Color.appPrimary.opacity(0.35), lineWidth: 1)
        }
        .padding(-Self.outlineInset)
        .mask {
            SweepWedge(progress: outlineProgress)
                .padding(-24)
        }
        .allowsHitTesting(false)
    }

    private func playReveal() {
        guard !reduceMotion else {
            outlineProgress = 1
            outlineGlow = 0.3
            return
        }
        withAnimation(.easeInOut(duration: 0.8).delay(0.15)) {
            outlineProgress = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.6)) {
                outlineGlow = 0.3
            }
        }
    }

    /// Lights the outline back up for a moment as the connection lands.
    private func flashOutline() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            outlineGlow = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.9)) {
                outlineGlow = 0.3
            }
        }
    }
}

/// Title, server and message under the status orb; each phase's copy blurs into the next.
private struct ConnectionStatusCaption: View {
    let status: ConnectionSetupStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
                .id(title)
                .transition(textTransition)

            if let serverName = status.serverName {
                Label(serverName, systemImage: "network")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.appTertiary.opacity(0.7), in: Capsule())
            }

            if let message {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appSecondary)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(message)
                    .transition(textTransition)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var textTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    private var title: String {
        switch status.phase {
        case .pairing: AppText.connectionPairing
        case .connecting: AppText.connecting
        case .reconnecting: AppText.reconnecting
        case .connected: AppText.connected
        case .failed(let title, _, _): title
        }
    }

    /// In-flight phases explain themselves only when there is no server to show instead.
    private var message: String? {
        switch status.phase {
        case .pairing: status.serverName == nil ? AppText.connectionPairingSubtitle : nil
        case .connecting: status.serverName == nil ? AppText.connectingSubtitle : nil
        case .reconnecting: status.serverName == nil ? AppText.reconnectingSubtitle : nil
        case .connected: nil
        case .failed(_, let message, _): message
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
    let sheet: ConnectionSetupSheet

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch sheet {
                    case .tips:
                        pairingTips
                    case .manualTips:
                        manualTips
                    }
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

    @ViewBuilder
    private var manualTips: some View {
        ConnectionSetupDetail(
            systemImage: "network",
            title: AppText.connectionManualTipsV2Title,
            text: AppText.connectionSetupHostnameDetail
        )
        ConnectionSetupDetail(
            systemImage: "terminal",
            title: AppText.connectionManualTipsV1Title,
            text: AppText.connectionManualTipsV1Detail
        )
    }

    @ViewBuilder
    private var pairingTips: some View {
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

#Preview("Pairing after a scan") {
    ConnectionWelcomePreview(step: .scanner, status: ConnectionSetupStatus(phase: .pairing))
}

#Preview("Connecting") {
    ConnectionWelcomePreview(
        step: .scanner,
        status: ConnectionSetupStatus(phase: .connecting, serverName: "192.168.1.50:4096")
    )
}

#Preview("Connected") {
    ConnectionWelcomePreview(
        step: .scanner,
        status: ConnectionSetupStatus(phase: .connected, serverName: "192.168.1.50:4096")
    )
}

#Preview("Connection failed") {
    ConnectionWelcomePreview(
        step: .manual,
        status: ConnectionSetupStatus(
            phase: .failed(
                title: AppText.manualConnectErrorTitle,
                message: AppText.manualConnectErrorBody,
                needsLocalNetworkAccess: false
            ),
            serverName: "192.168.1.50:4096"
        )
    )
}

#Preview("Local network access needed") {
    ConnectionWelcomePreview(
        step: .scanner,
        status: ConnectionSetupStatus(
            phase: .failed(
                title: AppText.localNetworkAccessRequiredTitle,
                message: AppText.localNetworkAccessRequiredBody,
                needsLocalNetworkAccess: true
            ),
            serverName: "192.168.1.50:4096"
        )
    )
}

private struct ConnectionWelcomePreview: View {
    @State private var step: ConnectionSetupStep
    @State private var status: ConnectionSetupStatus?
    @State private var serverURL = ""

    init(step: ConnectionSetupStep, status: ConnectionSetupStatus? = nil) {
        _step = State(initialValue: step)
        _status = State(initialValue: status)
    }

    var body: some View {
        NavigationStack {
            ConnectionWelcomeView(
                step: $step,
                status: status,
                isCameraActive: false,
                canConnectManually: !serverURL.isEmpty,
                onScanned: { _ in },
                onConnectManually: {
                    status = ConnectionSetupStatus(phase: .connecting, serverName: serverURL)
                },
                onRetry: { status?.phase = .connecting },
                onCancel: { status = nil },
                onOpenSettings: {}
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
    ConnectionSetupTipsView(sheet: .tips)
}

#Preview("Manual connection tips") {
    ConnectionSetupTipsView(sheet: .manualTips)
}
