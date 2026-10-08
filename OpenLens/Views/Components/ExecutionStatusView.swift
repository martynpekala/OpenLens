import SwiftUI

/// The current execution state, with the server's idle time for terminal results.
struct ExecutionStatusView: View {
    let state: OCExecutionState
    let idleTime: Double?

    private var color: Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .working, .waitingPermission, .waitingForm: .orange
        case .interrupted, .unknown: Color.appSecondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Label(state.label, systemImage: state.icon)
                .foregroundStyle(color)
            if state == .succeeded || state == .failed || state == .interrupted,
               let idleTime {
                Text("·")
                Text(Date(timeIntervalSince1970: idleTime / 1000), format: .relative(presentation: .named, unitsStyle: .abbreviated))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(Color.appSecondary)
        .accessibilityElement(children: .combine)
    }
}
