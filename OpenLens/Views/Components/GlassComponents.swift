import SwiftUI

// MARK: - Glass Components (legacy, backward compat)

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

struct GlassIcon: View {
    let icon: String
    var size: CGFloat = 40
    var iconSize: CGFloat = 18

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: iconSize))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color(.systemGray5))
            )
    }
}

struct GlassDivider: View {
    var body: some View {
        Divider()
            .opacity(0.3)
            .padding(.leading, 16)
    }
}

// MARK: - Surface Components (Warm Minimal design system)

/// Biała karta z delikatnym cieniem — zastępuje GlassCard w nowym designie.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appSurface)
            )
            .surfaceShadow()
    }
}

/// Separator wewnątrz SurfaceCard — cieńszy i cieplejszy niż GlassDivider.
struct SurfaceDivider: View {
    var leadingPadding: CGFloat = 0
    var body: some View {
        Color.appSeparator
            .frame(height: 0.5)
            .padding(.leading, leadingPadding)
    }
}

/// Uppercase label sekcji, zastępuje header z GlassIcon.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.appSecondary)
            .kerning(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
