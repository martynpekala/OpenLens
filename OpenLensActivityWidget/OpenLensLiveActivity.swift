import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Design tokens (mirrored from main app DesignTokens.swift)

private extension UIColor {
    static func openLens(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
}

private extension Color {
    static func openLensDynamic(light: UIColor, dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    static let laBackground = openLensDynamic(
        light: .openLens(245, 244, 242),
        dark: .openLens(20, 21, 24)
    )
    static let laPrimary = openLensDynamic(
        light: .openLens(26, 26, 26),
        dark: .openLens(245, 244, 242)
    )
    static let laSecondary = openLensDynamic(
        light: .openLens(107, 107, 107),
        dark: .openLens(171, 168, 161)
    )
    static let laTertiary = openLensDynamic(
        light: .openLens(239, 237, 233),
        dark: .openLens(44, 46, 51)
    )
    static let laSeparator = openLensDynamic(
        light: .openLens(224, 222, 221),
        dark: .openLens(64, 66, 71)
    )
    static let laAccent = openLensDynamic(
        light: .openLens(26, 26, 26),
        dark: .openLens(239, 237, 233)
    )
    static let laOnAccent = openLensDynamic(
        light: .white,
        dark: .openLens(26, 26, 26)
    )
}

// MARK: - Widget

struct OpenLensLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenLensActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            let state = context.state
            let status = ActivityStatus(state: state)

            // Everything shares one leading edge: the orb and timer sit beside the camera and the
            // copy runs underneath, instead of starting in the center region right of the orb.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // Inset by the outline so the ring, not the disc, lines up with the copy below.
                    StatusOrb(
                        symbol: status.symbol,
                        size: IslandLayout.orbSize,
                        accessibilityTitle: state.activePrompt == nil ? nil : status.title
                    )
                    .padding(.leading, IslandLayout.inset + ActivityDotField.orbOutlineInset)
                    .islandAppearance()
                }

                DynamicIslandExpandedRegion(.trailing) {
                    TimerPill(state: state)
                        .padding(.trailing, IslandLayout.inset)
                        .islandAppearance()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedIslandContent(state: state, attributes: context.attributes)
                        .padding(.horizontal, IslandLayout.inset)
                        .islandAppearance()
                }
            } compactLeading: {
                StatusGlyph(symbol: status.symbol)
                    .islandAppearance()
            } compactTrailing: {
                Group {
                    if let label = status.compactLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    } else {
                        ElapsedTime(state: state)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Color.laPrimary)
                .islandAppearance()
            } minimal: {
                StatusGlyph(symbol: status.symbol)
                    .islandAppearance()
            }
            .widgetURL(context.attributes.sessionURL)
        }
    }
}

// MARK: - Status

/// Generic copy for where the turn stands. The agent's own progress messages are deliberately
/// left out; only a prompt waiting on the user shows its details, so it can be answered safely.
private struct ActivityStatus {
    let symbol: String
    let title: String
    let message: String
    /// Short label for the compact Dynamic Island; nil shows the elapsed time instead.
    let compactLabel: String?

    init(state: OpenLensActivityAttributes.ContentState) {
        switch (state.phase, state.activePrompt?.kind) {
        case (.working, .permission?):
            symbol = "hand.raised"
            title = "Needs your approval"
            message = "Review the request before you allow it."
            compactLabel = "Approve"
        case (.working, .question?), (.working, .form?):
            symbol = "questionmark.bubble"
            title = "Has a question"
            message = "Answer it so OpenCode can continue."
            compactLabel = "Answer"
        case (.working, nil):
            symbol = "sparkles"
            title = "Working on it"
            message = "OpenCode will let you know if it needs you."
            compactLabel = nil
        case (.finished, _):
            symbol = "checkmark"
            title = "All done"
            message = "Tap to see the result."
            compactLabel = "Done"
        case (.stopped, _):
            symbol = "stop.fill"
            title = "Stopped"
            message = "Tap to pick up where it left off."
            compactLabel = "Stopped"
        case (.failed, _):
            symbol = "exclamationmark"
            title = "Something went wrong"
            message = "Tap to see what happened."
            compactLabel = "Failed"
        }
    }
}

private extension OpenLensActivityAttributes.ContentState {
    /// The prompt to show, only while the turn is still waiting on it.
    var activePrompt: OpenLensActivityAttributes.PendingUserResponse? {
        isFinished ? nil : pendingUserResponse
    }
}

private extension OpenLensActivityAttributes.PendingUserResponse {
    /// Three or four answers wrap into two rows of smaller buttons.
    var usesReplyGrid: Bool {
        kind != .permission && quickReplies.count > 2
    }
}

private extension OpenLensActivityAttributes {
    /// The project folder the turn runs in, shown above the title.
    var projectName: String {
        let name = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return name.isEmpty || name == "/" ? "OpenCode" : name
    }
}

private extension View {
    /// The Dynamic Island is always black, so it uses the dark palette whatever the system setting.
    func islandAppearance() -> some View {
        environment(\.colorScheme, .dark)
    }
}

// MARK: - Dynamic Island

private enum IslandLayout {
    /// Extra room inside the island's own content margins, shared by every expanded region.
    static let inset: CGFloat = 4
    static let orbSize: CGFloat = 32
}

/// The expanded island's bottom region: the status copy, or the prompt and its buttons.
private struct ExpandedIslandContent: View {
    let state: OpenLensActivityAttributes.ContentState
    let attributes: OpenLensActivityAttributes

    var body: some View {
        let status = ActivityStatus(state: state)

        Group {
            if let prompt = state.activePrompt {
                // The expanded island is capped at 160pt, so a prompt skips the title: the orb says
                // what kind it is and the room goes to the request and its buttons.
                VStack(alignment: .leading, spacing: prompt.usesReplyGrid ? 6 : 8) {
                    PromptDetail(prompt: prompt)
                    PromptActions(
                        prompt: prompt,
                        sessionURL: attributes.sessionURL,
                        buttonHeight: 34,
                        gridButtonHeight: 26
                    )
                }
                .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(attributes.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.laSecondary)
                        .lineLimit(1)

                    Text(status.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.laPrimary)
                        .lineLimit(1)
                        .padding(.top, 1)

                    Text(status.message)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.laSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 4)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<OpenLensActivityAttributes>

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let state = context.state
        let status = ActivityStatus(state: state)
        let prompt = state.activePrompt

        // Same shape as the expanded island: the orb and timer on top, then everything else on the
        // ring's edge. The Lock Screen is also capped at 160pt, so a prompt moves the title up
        // beside the orb and gives the room below to the request and its buttons.
        VStack(alignment: .leading, spacing: prompt?.usesReplyGrid == true ? 8 : 10) {
            HStack(spacing: 12) {
                StatusOrb(symbol: status.symbol, size: 36)
                    .anchorPreference(key: OrbBoundsKey.self, value: .bounds) { $0 }
                    .padding(.leading, ActivityDotField.orbOutlineInset)

                if prompt != nil {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.attributes.projectName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.laSecondary)
                            .lineLimit(1)

                        Text(status.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.laPrimary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                TimerPill(state: state)
            }

            if let prompt {
                PromptDetail(prompt: prompt)
                PromptActions(
                    prompt: prompt,
                    sessionURL: context.attributes.sessionURL,
                    buttonHeight: 34,
                    gridButtonHeight: 26
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(context.attributes.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.laSecondary)
                        .lineLimit(1)

                    Text(status.title)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.laPrimary)
                        .lineLimit(1)
                        .padding(.top, 1)

                    Text(status.message)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.laSecondary)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, prompt == nil ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(OrbBoundsKey.self) { anchor in
            if !isLuminanceReduced {
                GeometryReader { proxy in
                    ActivityDotField(focus: anchor.map { proxy[$0] })
                }
            }
        }
        .activityBackgroundTint(Color.laBackground)
        .activitySystemActionForegroundColor(Color.laPrimary)
        .widgetURL(context.attributes.sessionURL)
    }
}

nonisolated private struct OrbBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - Status Orb

/// The connection screen's status orb: a symbol on a soft disc inside a glowing outline.
private struct StatusOrb: View {
    let symbol: String
    let size: CGFloat
    /// Read by VoiceOver where no title is shown next to the orb.
    var accessibilityTitle: String?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(Color.laPrimary)
            .frame(width: size, height: size)
            .background(Color.laTertiary.opacity(0.7), in: Circle())
            .overlay {
                ZStack {
                    Circle()
                        .stroke(Color.laPrimary.opacity(0.8), lineWidth: 2)
                        .blur(radius: 4)
                        .opacity(0.3)
                    Circle()
                        .stroke(Color.laPrimary.opacity(0.35), lineWidth: 1)
                }
                .padding(-ActivityDotField.orbOutlineInset)
            }
            .accessibilityHidden(accessibilityTitle == nil)
            .accessibilityLabel(accessibilityTitle ?? "")
    }
}

/// A small orb for the compact and minimal Dynamic Island.
private struct StatusGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.laPrimary)
            .frame(width: 22, height: 22)
            .background(Color.laTertiary, in: Circle())
            .overlay {
                Circle().stroke(Color.laPrimary.opacity(0.35), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Elapsed Time

private struct ElapsedTime: View {
    let state: OpenLensActivityAttributes.ContentState

    var body: some View {
        if let endDate = state.endDate {
            Text(Self.formatted(endDate.timeIntervalSince(state.startDate)))
        } else {
            // A timer claims all the width it's offered; the placeholder keeps it to its digits.
            Text("00:00")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(state.startDate, style: .timer)
                        .multilineTextAlignment(.trailing)
                }
        }
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        let seconds = max(interval, 0).rounded()
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The elapsed time on a soft capsule, with a dot while the turn is still running.
private struct TimerPill: View {
    let state: OpenLensActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 5) {
            if !state.isFinished {
                Circle()
                    .fill(Color.laPrimary)
                    .frame(width: 5, height: 5)
            }
            ElapsedTime(state: state)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Color.laPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.laTertiary.opacity(0.7), in: Capsule())
    }
}

// MARK: - Prompt

/// What the prompt asks: the permission's command, or the question itself.
private struct PromptDetail: View {
    let prompt: OpenLensActivityAttributes.PendingUserResponse

    var body: some View {
        if prompt.kind == .permission {
            // Full width, so the command block ends where the buttons under it do.
            Text(prompt.detail)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.laPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Color.laTertiary.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        } else {
            Text(prompt.detail)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.laPrimary)
                .lineLimit(prompt.usesReplyGrid ? 1 : 2)
        }
    }
}

/// Buttons that answer the prompt in place, or a link into the app when it needs the full sheet.
private struct PromptActions: View {
    let prompt: OpenLensActivityAttributes.PendingUserResponse
    let sessionURL: URL?
    let buttonHeight: CGFloat
    let gridButtonHeight: CGFloat

    var body: some View {
        if let requestID = prompt.requestID, !requestID.isEmpty {
            switch prompt.kind {
            case .permission:
                HStack(spacing: 8) {
                    Button(intent: DenyPermissionIntent(requestID: requestID)) {
                        ActionCapsule(title: "Deny", isPrimary: false, height: buttonHeight)
                    }
                    Button(intent: ApprovePermissionIntent(requestID: requestID)) {
                        ActionCapsule(title: "Allow", isPrimary: true, height: buttonHeight)
                    }
                }
                .buttonStyle(.plain)
            case .question, .form:
                if prompt.quickReplies.isEmpty {
                    openButton
                } else {
                    replyButtons(requestID: requestID)
                }
            }
        } else {
            openButton
        }
    }

    private func replyButtons(requestID: String) -> some View {
        let count = prompt.quickReplies.count
        let rows = stride(from: 0, to: count, by: 2).map { Array($0..<min($0 + 2, count)) }
        let height = rows.count > 1 ? gridButtonHeight : buttonHeight

        return VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { index in
                        Button(intent: AnswerPromptIntent(requestID: requestID, replyIndex: index)) {
                            ActionCapsule(title: prompt.quickReplies[index].label, isPrimary: false, height: height)
                        }
                    }
                    if rows.count > 1, row.count == 1 {
                        // Keeps a lone last answer the same width as the ones above it.
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: height)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var openButton: some View {
        let label = ActionCapsule(title: "Open to answer", isPrimary: true, height: buttonHeight)
        if let sessionURL {
            Link(destination: sessionURL) { label }
        } else {
            label
        }
    }
}

/// The connection screen's capsule button: accent fill for the main action, outline otherwise.
private struct ActionCapsule: View {
    let title: String
    let isPrimary: Bool
    let height: CGFloat

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isPrimary ? Color.laOnAccent : Color.laPrimary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(isPrimary ? Color.laAccent : Color.laBackground.opacity(0.85), in: Capsule())
            .overlay {
                if !isPrimary {
                    Capsule().stroke(Color.laSeparator, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }
}

// MARK: - Dot Field

/// A still frame of the connection screen's glow dot field: dots on a perspective wave surface
/// with glowing crests, gathered into a halo around the status orb. Live Activities don't run
/// animations, so the field is drawn once per update and fades out behind the copy and buttons.
private struct ActivityDotField: View {
    static let orbOutlineInset: CGFloat = 5

    private static let spacing = 18.0
    /// Depth of the first row; slightly nearer than the bottom edge so lifted dots never leave a gap.
    private static let nearDepth = 0.94
    /// The moment of the wave surface the field freezes on.
    private static let time = 2.0
    private static let dotBuckets = 8
    private static let glowBuckets = 6

    var focus: CGRect?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Canvas { context, size in
            Self.draw(in: &context, size: size, focus: focus, isDark: isDark)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, focus: CGRect?, isDark: Bool) {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > 0, height > 0 else { return }

        // The vanishing line sits above the banner, so the plane recedes without a visible horizon.
        let horizon = -1.1 * height
        let depthSpan = height - horizon
        let centerX = width / 2
        let rowDepth = spacing / depthSpan
        let topDepth = depthSpan / -horizon
        let topScale = 1 / topDepth
        let rowCount = Int(((topDepth + 2 * rowDepth) - nearDepth) / rowDepth) + 2

        let baseAlpha = isDark ? 0.18 : 0.13
        let crestAlpha = isDark ? 0.55 : 0.38
        let maxAlpha = baseAlpha + crestAlpha
        let glowOpacity = isDark ? 0.6 : 0.16
        let orbRadius = focus.map { Double($0.width) / 2 + Double(orbOutlineInset) } ?? 0

        var dots = Array(repeating: Path(), count: dotBuckets)
        var glows = Array(repeating: Path(), count: glowBuckets)

        for row in 0..<rowCount {
            let depth = nearDepth + Double(row) * rowDepth
            let scale = 1 / depth
            let depthFade = smoothstep(topScale, topScale + 0.2, scale)
            guard depthFade > 0 else { continue }

            let baseY = horizon + depthSpan * scale
            let worldDepth = Double(row) * spacing
            let parity = row.isMultiple(of: 2) ? 0 : 0.5
            let columns = Int(((width / 2 + spacing) / scale / spacing).rounded(.up))

            for column in -columns...columns {
                let worldX = (Double(column) + parity) * spacing
                let surface = surfaceHeight(x: worldX, z: worldDepth)
                var glow = smoothstep(0.15, 0.95, surface)
                var x = centerX + worldX * scale
                var y = baseY - surface * 18 * scale * 0.75
                var alphaScale = depthFade

                if let focus {
                    let dx = x - Double(focus.midX)
                    let dy = y - Double(focus.midY)
                    let centerDistance = hypot(dx, dy)
                    let distance = centerDistance - orbRadius
                    guard distance > 0 else { continue }

                    let halo = exp(-distance / 26)
                    let pull = min(distance, 12) * halo
                    x -= dx / centerDistance * pull
                    y -= dy / centerDistance * pull
                    glow += halo * 1.3 * (0.65 + 0.35 * cos(atan2(dy, dx) - time * 1.6))
                    alphaScale *= 0.1 + 0.9 * exp(-distance / 90)
                }

                guard x > -8, x < width + 8, y > -8, y < height + 8 else { continue }

                let intensity = min(glow, 1.8)
                let alpha = (baseAlpha + crestAlpha * min(intensity, 1)) * alphaScale
                guard alpha > 0.01 else { continue }

                let radius = (0.9 + min(intensity, 1.4)) * max(scale, 0.5)
                let bucket = min(Int(alpha / maxAlpha * Double(dotBuckets)), dotBuckets - 1)
                dots[bucket].addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))

                if intensity > 0.3 {
                    let glowAlpha = (intensity - 0.3) * alphaScale
                    let glowBucket = min(Int(glowAlpha / 1.5 * Double(glowBuckets)), glowBuckets - 1)
                    let glowRadius = radius * 3.6
                    glows[glowBucket].addEllipse(
                        in: CGRect(x: x - glowRadius, y: y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)
                    )
                }
            }
        }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            for (index, path) in glows.enumerated() where !path.isEmpty {
                let opacity = (Double(index) + 0.5) / Double(glowBuckets) * glowOpacity
                layer.fill(path, with: .color(Color.laPrimary.opacity(opacity)))
            }
        }
        for (index, path) in dots.enumerated() where !path.isEmpty {
            let opacity = (Double(index) + 0.5) / Double(dotBuckets) * maxAlpha
            context.fill(path, with: .color(Color.laPrimary.opacity(opacity)))
        }
    }

    /// Height of the wave surface in -1...1 at a world position, matching the app's field.
    private static func surfaceHeight(x: Double, z: Double) -> Double {
        let swell = sin(z * 0.011 + x * 0.003 + time * 0.9)
        let cross = sin(x * 0.009 - z * 0.004 - time * 0.5)
        let chop = sin((x + z) * 0.017 + time * 1.2)
        return 0.5 * swell + 0.3 * cross + 0.2 * chop
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.working
    OpenLensActivityAttributes.ContentState.waitingForPermission
    OpenLensActivityAttributes.ContentState.waitingForAnswer
    OpenLensActivityAttributes.ContentState.waitingForOpenAnswer
    OpenLensActivityAttributes.ContentState.finished
    OpenLensActivityAttributes.ContentState(phase: .failed, startDate: .now.addingTimeInterval(-42), endDate: .now)
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.working
    OpenLensActivityAttributes.ContentState.waitingForPermission
    OpenLensActivityAttributes.ContentState.waitingForAnswer
    OpenLensActivityAttributes.ContentState.waitingForOpenAnswer
    OpenLensActivityAttributes.ContentState.finished
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.working
    OpenLensActivityAttributes.ContentState.waitingForPermission
    OpenLensActivityAttributes.ContentState.finished
}
