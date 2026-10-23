import SwiftUI

extension EnvironmentValues {
    /// Opens a subagent's conversation from a card in the current chat. Nil
    /// where navigation is unavailable, so cards hide the action.
    @Entry var openChildSession: OpenChildSessionAction?
}

struct OpenChildSessionAction {
    let open: (String) -> Void

    func callAsFunction(_ childSessionID: String) {
        open(childSessionID)
    }
}

/// Compact link shown on delegated-work cards that name a child session.
struct OpenChildSessionButton: View {
    let childSessionID: String
    let usesRetroTypography: Bool
    let action: OpenChildSessionAction

    var body: some View {
        Button {
            action(childSessionID)
        } label: {
            Label(AppText.openChildSession, systemImage: "arrow.up.right.circle")
                .font(usesRetroTypography ? RetroChatStyle.smallFont : .system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("open-child-\(childSessionID)")
    }
}
