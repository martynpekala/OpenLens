import SwiftUI

/// Shared chrome for the toolbar capsules (connected host, review session
/// picker, workspace project title): one glass shape, one padding scale, one
/// width ceiling, so every tab's principal control reads as the same family.
struct GlassToolbarCapsule<Content: View>: View {
    let isInteractive: Bool
    let content: () -> Content

    init(isInteractive: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isInteractive = isInteractive
        self.content = content
    }

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: 240)
        .glassEffect(isInteractive ? .regular.interactive() : .regular, in: Capsule())
        .contentShape(Capsule())
    }
}
