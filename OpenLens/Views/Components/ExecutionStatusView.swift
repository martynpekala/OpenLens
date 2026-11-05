import SwiftUI

/// The current execution state, with the server's idle time for terminal results.
/// `isCompact` renders a bounded icon + time form for dense rows: the label is
/// dropped visually but kept for accessibility, and the view never wraps.
struct ExecutionStatusView: View {
    let state: OCExecutionState
    let idleTime: Double?
    var isCompact = false

    private var color: Color {
        switch state {
        case .succeeded: Color.appSuccess
        case .failed: Color.appDanger
        case .working, .waitingPermission, .waitingForm: Color.appWarning
        case .interrupted, .unknown: Color.appSecondary
        }
    }

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 4) {
            Image(systemName: state.icon)
                .foregroundStyle(color)
            Text(relativeIdleText ?? state.label)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(Color.appSecondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var fullBody: some View {
        HStack(spacing: 5) {
            Label(state.label, systemImage: state.icon)
                .foregroundStyle(color)
            if let relativeIdleText {
                Text("·")
                Text(relativeIdleText)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(Color.appSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Terminal results carry the server's idle time; other states do not.
    private var relativeIdleText: String? {
        guard state == .succeeded || state == .failed || state == .interrupted,
              let idleTime else { return nil }
        return Date(timeIntervalSince1970: idleTime / 1000)
            .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var accessibilityText: String {
        relativeIdleText.map { "\(state.label), \($0)" } ?? state.label
    }
}
