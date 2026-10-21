import SwiftUI

/// Admission belongs to the shared chat service so dismissing this sheet does
/// not reset a request or turn reopening into another submission.
struct SessionCompactionControls: View {
    @Environment(ChatClient.self) private var chatClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatEasterEgg) private var chatEasterEgg

    private var state: ChatClient.CompactionState {
        ScreenshotFixtures.compactionState ?? chatClient.compactionState
    }
    private var isRetro: Bool { chatEasterEgg.visualMode.isRetro }
    private var canRequest: Bool {
        ScreenshotFixtures.canRequestCompaction ?? chatClient.canRequestCompaction
    }
    private var isWorking: Bool { state == .submitting || state == .pending || state == .running }

    var body: some View {
        VStack(spacing: 10) {
            if let status {
                Text(status)
                    .font(isRetro ? RetroChatStyle.smallFont : .footnote)
                    .foregroundStyle(isRetro ? RetroChatStyle.secondaryInk : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: compactAndDismiss) {
                Text(buttonTitle)
                    .font(isRetro ? RetroChatStyle.bodyFont : .body.weight(.semibold))
                    .foregroundStyle(isRetro ? Color.white : Color.appOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .overlay(alignment: .leading) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(.borderedProminent)
            .tint(isRetro ? nil : Color.appAccent)
            .controlSize(.large)
            .disabled(!canRequest)
            .accessibilityIdentifier("active-context-compact")
        }
        .accessibilityIdentifier("active-context-compaction-status")
    }

    private func compactAndDismiss() {
        let chat = chatClient
        Task { await chat.requestCompaction() }
        dismiss()
    }

    private var buttonTitle: String {
        switch state {
        case .submitting: "Requesting…"
        case .pending: "Compaction pending"
        case .running: "Compacting…"
        case .uncertain: "Retry compaction"
        default: "Compact"
        }
    }

    private var status: String? {
        switch state {
        case .ready:
            canRequest
                ? nil
                : "Reconnect and refresh Chat to compact this conversation."
        case .submitting, .pending, .running, .completed, .failed, .interrupted: nil
        case .uncertain: "The request may still be pending. Retrying won't create another compaction."
        case .unavailable: "This connection doesn't support compaction."
        }
    }
}
