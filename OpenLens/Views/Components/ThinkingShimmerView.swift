import SwiftUI

/// A single grey status line with a shimmer animation showing what the agent is
/// currently doing (e.g. "Thinking...", "Reading main.swift...").
struct ThinkingShimmerView: View {
    let label: String
    var onTap: () -> Void = {}

    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.appSecondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .opacity(shimmerPhase > 0 ? 0.3 : 1.0)

            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .lineLimit(1)
                .overlay(shimmerOverlay)
                .mask(
                    Text(label)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .lineLimit(1)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface)
        )
        .surfaceShadow()
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                shimmerPhase = 1
            }
        }
        .onDisappear {
            // Explicitly cancel the repeating animation so the render loop stops
            // when the shimmer leaves the hierarchy (e.g. agent finishes a step).
            withAnimation(.default.speed(100)) {
                shimmerPhase = -1
            }
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.appSecondary.opacity(0.2),
                    Color.appSecondary.opacity(0.6),
                    Color.appSecondary.opacity(0.2),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .offset(x: shimmerPhase * geo.size.width * 0.7)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ThinkingShimmerView(label: "Thinking...")
        ThinkingShimmerView(label: "Reading main.swift...")
        ThinkingShimmerView(label: "Editing ContentView.swift...")
    }
    .padding()
}
