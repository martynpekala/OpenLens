import ActivityKit
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
    static let laSurface = openLensDynamic(
        light: .white,
        dark: .openLens(30, 32, 36)
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
}

// MARK: - Widget

struct OpenLensLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenLensActivityAttributes.self) { context in
            lockScreenBanner(context: context)
        } dynamicIsland: { context in
            let pendingUserResponse = context.state.pendingUserResponse
            let statusText = pendingUserResponse?.kind.statusText ?? context.state.currentIntent

            return DynamicIsland {
                // Expanded leading — pulsing dot
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        Circle()
                            .fill(Color.laTertiary)
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(context.state.isFinished ? Color.laSecondary : Color.laPrimary)
                            .frame(width: 8, height: 8)
                            .symbolEffect(.pulse, isActive: !context.state.isFinished)
                    }
                    .padding(.leading, 4)
                    .padding(.top, 4)
                }

                // Expanded center — agent name + current action
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.agentName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.laPrimary)
                            .lineLimit(1)
                        Text(context.state.isFinished ? "Finished" : statusText)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color.laSecondary)
                            .lineLimit(1)
                            .transition(.blurReplace)
                    }
                }

                // Expanded trailing — step counter or checkmark
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isFinished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.laSecondary)
                            .padding(.trailing, 4)
                    } else if let pendingUserResponse {
                        Text(pendingUserResponse.kind.compactText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.laSecondary)
                            .padding(.trailing, 4)
                    } else {
                        Text("Step \(context.state.stepNumber)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.laSecondary)
                            .padding(.trailing, 4)
                    }
                }

                // Expanded bottom — last completed step
                DynamicIslandExpandedRegion(.bottom) {
                    if let prev = context.state.previousIntent, !context.state.isFinished {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.laSecondary)
                            Text(prev)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.laSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .transition(.blurReplace)
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.isFinished ? Color.laSecondary : Color.laPrimary)
                    .frame(width: 6, height: 6)
                    .padding(.leading, 2)
            } compactTrailing: {
                if context.state.isFinished {
                    Text("Done")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.laSecondary)
                } else {
                    Text(pendingUserResponse?.kind.compactText ?? statusText)
                        .font(.system(size: 11, design: .rounded))
                        .lineLimit(1)
                        .frame(maxWidth: 72)
                        .foregroundStyle(Color.laPrimary)
                }
            } minimal: {
                Circle()
                    .fill(context.state.isFinished ? Color.laSecondary : Color.laPrimary)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenBanner(context: ActivityViewContext<OpenLensActivityAttributes>) -> some View {
        let state = context.state
        let pendingUserResponse = state.pendingUserResponse

        let intents: [String] = [state.secondPreviousIntent, state.previousIntent]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let isInitialState = intents.isEmpty && pendingUserResponse == nil
        let statusText = pendingUserResponse?.kind.statusText ?? (state.isFinished ? "Finished" : state.currentIntent)

        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 8) {
                // OC badge
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.laTertiary)
                        .frame(width: 28, height: 28)
                    Text("OC")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.laPrimary)
                }

                // Subject / agent name
                Group {
                    if isInitialState || state.isFinished {
                        Text(context.attributes.agentName)
                    } else {
                        Text(state.subject ?? context.attributes.agentName)
                            .id(state.subject)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.laPrimary)
                .lineLimit(1)
                .transition(.blurReplace)

                Spacer()

                // Cost badge or live indicator
                if let cost = state.costTotal {
                    let highlighted = !cost.contains("$0.00") && !cost.contains("$0.0")
                    Text(cost)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(highlighted ? Color.laPrimary : Color.laSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(highlighted ? Color.laTertiary : Color.laSeparator.opacity(0.6))
                        )
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.laPrimary)
                            .frame(width: 5, height: 5)
                            .symbolEffect(.pulse)
                        Text("OpenCode")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.laSecondary)
                    }
                    .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Intent cards / finished state
            ZStack {
                if state.isFinished {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.laPrimary)
                        Text(state.subject ?? "Task complete")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.laPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.blurReplace)
                } else if let pendingUserResponse {
                    PendingUserResponseCard(response: pendingUserResponse)
                        .padding(.horizontal, 14)
                        .transition(.blurReplace)
                } else if isInitialState {
                    // Initial state — show user task as bubble
                    Text(context.attributes.userTask)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.laPrimary.opacity(0.7))
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.laSurface)
                                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .transition(.blurReplace)
                } else {
                    ZStack {
                        ForEach(intents, id: \.self) { intent in
                            let isBehind = intent != state.previousIntent
                            IntentCard(text: intent, isBehind: isBehind)
                                .padding(.horizontal, 14)
                        }
                    }
                    .compositingGroup()
                    .transition(.blurReplace)
                }
            }
            .frame(height: 72)
            .frame(maxHeight: .infinity)

            // Footer — current intent + timer
            HStack(spacing: 4) {
                if state.isFinished {
                    Text("^[\(state.stepNumber) step](inflect: true) completed")
                        .transition(.blurReplace)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: pendingUserResponse?.kind.iconName ?? state.currentIntentIcon ?? "arrow.turn.down.right")
                            .font(.system(size: 10))
                            .frame(width: 16)
                        Text(isInitialState ? "Thinking..." : statusText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(statusText)
                    .transition(.blurReplace)
                }

                Spacer(minLength: 8)

                Group {
                    if let endDate = state.intentEndDate {
                        let interval = Duration.seconds(endDate.timeIntervalSince(state.intentStartDate))
                        Text("Finished in \(interval.formatted(.time(pattern: .minuteSecond)))")
                    } else if !isInitialState {
                        Text("00:00")
                            .opacity(0)
                            .overlay(alignment: .trailing) {
                                Text(state.intentStartDate, style: .timer)
                                    .contentTransition(.numericText(countsDown: false))
                                    .opacity(0.5)
                            }
                    }
                }
                .monospacedDigit()
                .layoutPriority(1)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.laSecondary)
            .opacity(isInitialState || state.isFinished ? 0.5 : 1)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(height: 160)
        .background(Color.laBackground)
        .activityBackgroundTint(Color.laBackground)
    }
}

// MARK: - Intent Card

struct IntentCard: View {
    let text: String
    let isBehind: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.laPrimary.opacity(0.5))
                .frame(width: 16)

            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.laPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: isBehind ? 10 : 16, style: .continuous)
                .fill(Color.laSurface)
                .shadow(color: .black.opacity(isBehind ? 0.03 : 0.06), radius: isBehind ? 4 : 8, y: 2)
        )
        .scaleEffect(isBehind ? 0.92 : 1)
        .offset(y: isBehind ? 8 : 0)
        .opacity(isBehind ? 0.6 : 1)
        .zIndex(isBehind ? 0 : 1)
        .transition(.asymmetric(
            insertion: .offset(y: 120),
            removal: .opacity
        ))
    }
}

struct PendingUserResponseCard: View {
    let response: OpenLensActivityAttributes.PendingUserResponse

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.laTertiary)
                    .frame(width: 28, height: 28)
                Image(systemName: response.kind.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.laPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(response.kind.cardTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.laPrimary)

                Text(response.detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.laSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.laSurface)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        )
    }
}

// MARK: - Previews

#Preview("Lock Screen - Steps", as: .content, using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.step1
    OpenLensActivityAttributes.ContentState.step2
    OpenLensActivityAttributes.ContentState.step3
    OpenLensActivityAttributes.ContentState.step4
    OpenLensActivityAttributes.ContentState.step5
    OpenLensActivityAttributes.ContentState.finished
}

#Preview("Lock Screen - Waiting for Permission", as: .content, using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.waitingForPermission
}

#Preview("Lock Screen - Waiting for Answer", as: .content, using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.waitingForAnswer
}

#Preview("Lock Screen - Finished", as: .content, using: OpenLensActivityAttributes.preview) {
    OpenLensLiveActivity()
} contentStates: {
    OpenLensActivityAttributes.ContentState.finished
}
