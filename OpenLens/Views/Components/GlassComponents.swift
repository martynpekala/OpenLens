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
    var cornerRadius: CGFloat?
    @ViewBuilder let content: Content

    @Environment(\.openLensTheme) private var theme

    var body: some View {
        let cardRadius = cornerRadius ?? theme.radius.card

        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .fill(theme.colors.surface.color)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(
                        theme.components.surfaceBorder.color.color,
                        lineWidth: theme.components.surfaceBorder.width
                    )
            }
            .overlay {
                let inset = theme.components.surfaceBorder.width + theme.components.surfaceInnerBorder.width / 2

                RoundedRectangle(cornerRadius: max(cardRadius - inset, 0), style: .continuous)
                    .inset(by: inset)
                    .stroke(
                        theme.components.surfaceInnerBorder.color.color,
                        lineWidth: theme.components.surfaceInnerBorder.width
                    )
            }
            .surfaceShadow()
    }
}

struct SurfaceIconTile: View {
    let icon: String
    var fill: Color?
    var foreground: Color?

    @Environment(\.openLensTheme) private var theme

    var body: some View {
        let tileRadius = theme.radius.iconTile
        let tileSize = theme.components.iconTileSize

        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground ?? theme.colors.secondary.color)
            .frame(width: tileSize, height: tileSize)
            .background(
                RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
                    .fill(fill ?? theme.colors.tertiary.color)
            )
            .overlay {
                RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
                    .stroke(
                        theme.components.iconTileBorder.color.color,
                        lineWidth: theme.components.iconTileBorder.width
                    )
            }
    }
}

/// Separator wewnątrz SurfaceCard — cieńszy i cieplejszy niż GlassDivider.
struct SurfaceDivider: View {
    var leadingPadding: CGFloat = 0

    @Environment(\.openLensTheme) private var theme

    var body: some View {
        theme.colors.separator.color
            .frame(height: 0.5)
            .padding(.leading, leadingPadding)
    }
}

/// Uppercase label sekcji, zastępuje header z GlassIcon.
struct SectionLabel: View {
    let text: String

    @Environment(\.openLensTheme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(theme.typography.sectionLabel)
            .foregroundStyle(theme.colors.secondary.color)
            .kerning(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}
