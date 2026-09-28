import Observation
import SwiftUI
import UIKit

// MARK: - Design System

private extension UIColor {
    static func openLens(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
}

struct OpenLensSemanticColor {
    let light: UIColor
    let dark: UIColor

    init(light: UIColor, dark: UIColor? = nil) {
        self.light = light
        self.dark = dark ?? light
    }

    var color: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? self.dark : self.light
            }
        )
    }
}

struct OpenLensColorTokens {
    let background: OpenLensSemanticColor
    let surface: OpenLensSemanticColor
    let primary: OpenLensSemanticColor
    let secondary: OpenLensSemanticColor
    let tertiary: OpenLensSemanticColor
    let separator: OpenLensSemanticColor
    let accent: OpenLensSemanticColor
    let onAccent: OpenLensSemanticColor
    let success: OpenLensSemanticColor
    let warning: OpenLensSemanticColor
    let danger: OpenLensSemanticColor
}

struct OpenLensTypographyTokens {
    let sectionLabel = Font.system(size: 12, weight: .semibold, design: .rounded)
    let rowTitle = Font.system(size: 15, weight: .medium, design: .rounded)
    let rowSubtitle = Font.system(size: 13)
    let body = Font.system(size: 15)
}

struct OpenLensSpacingTokens {
    let xSmall: CGFloat = 4
    let small: CGFloat = 8
    let medium: CGFloat = 12
    let large: CGFloat = 16
    let xLarge: CGFloat = 20
    let xxLarge: CGFloat = 24
}

struct OpenLensRadiusTokens {
    let control: CGFloat = 14
    let iconTile: CGFloat = 10
    let card: CGFloat = 20
    let largeCard: CGFloat = 24
    let heroCard: CGFloat = 36
}

struct OpenLensShadowStyle {
    let color: OpenLensSemanticColor
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

struct OpenLensShadowTokens {
    let surface: OpenLensShadowStyle
    let subtle: OpenLensShadowStyle
}

struct OpenLensStrokeStyle {
    let color: OpenLensSemanticColor
    let width: CGFloat

    static let none = OpenLensStrokeStyle(
        color: .init(light: .clear),
        width: 0
    )
}

struct OpenLensComponentTokens {
    let cardPadding: CGFloat
    let rowHorizontalPadding: CGFloat
    let rowVerticalPadding: CGFloat
    let iconTileSize: CGFloat
    let surfaceBorder: OpenLensStrokeStyle
    let surfaceInnerBorder: OpenLensStrokeStyle
    let controlBorder: OpenLensStrokeStyle
    let iconTileBorder: OpenLensStrokeStyle

    init(
        cardPadding: CGFloat = 16,
        rowHorizontalPadding: CGFloat = 16,
        rowVerticalPadding: CGFloat = 14,
        iconTileSize: CGFloat = 36,
        surfaceBorder: OpenLensStrokeStyle = .none,
        surfaceInnerBorder: OpenLensStrokeStyle = .none,
        controlBorder: OpenLensStrokeStyle = .none,
        iconTileBorder: OpenLensStrokeStyle = .none
    ) {
        self.cardPadding = cardPadding
        self.rowHorizontalPadding = rowHorizontalPadding
        self.rowVerticalPadding = rowVerticalPadding
        self.iconTileSize = iconTileSize
        self.surfaceBorder = surfaceBorder
        self.surfaceInnerBorder = surfaceInnerBorder
        self.controlBorder = controlBorder
        self.iconTileBorder = iconTileBorder
    }
}

struct OpenLensTheme {
    let id: String
    let name: String
    let colors: OpenLensColorTokens
    let typography: OpenLensTypographyTokens
    let spacing: OpenLensSpacingTokens
    let radius: OpenLensRadiusTokens
    let shadow: OpenLensShadowTokens
    let components: OpenLensComponentTokens
}

enum OpenLensAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "openLensAppearance"
    static let fallback: OpenLensAppearance = .classic

    case classic
    case graphite
    case meadow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .graphite: "Graphite"
        case .meadow: "Meadow"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "Warm neutral"
        case .graphite: "Cool graphite"
        case .meadow: "Soft green"
        }
    }

    var theme: OpenLensTheme {
        switch self {
        case .classic: .classic
        case .graphite: .graphite
        case .meadow: .meadow
        }
    }

    static var current: OpenLensAppearance {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
                  let appearance = OpenLensAppearance(rawValue: rawValue)
            else {
                return .fallback
            }
            return appearance
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}

extension OpenLensTheme {
    static let classic = OpenLensTheme(
        id: "classic",
        name: "Classic",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(245, 244, 242), dark: .openLens(20, 21, 24)),
            surface: .init(light: .white, dark: .openLens(30, 32, 36)),
            primary: .init(light: .openLens(26, 26, 26), dark: .openLens(245, 244, 242)),
            secondary: .init(light: .openLens(107, 107, 107), dark: .openLens(171, 168, 161)),
            tertiary: .init(light: .openLens(239, 237, 233), dark: .openLens(44, 46, 51)),
            separator: .init(light: .openLens(224, 222, 221), dark: .openLens(64, 66, 71)),
            accent: .init(light: .openLens(26, 26, 26), dark: .openLens(239, 237, 233)),
            onAccent: .init(light: .white, dark: .openLens(26, 26, 26)),
            success: .init(light: .openLens(31, 145, 84), dark: .openLens(77, 199, 130)),
            warning: .init(light: .openLens(194, 117, 35), dark: .openLens(235, 166, 78)),
            danger: .init(light: .openLens(208, 58, 58), dark: .openLens(255, 112, 112))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(0, 0, 0, alpha: 0.06), dark: .openLens(0, 0, 0, alpha: 0.32)),
                radius: 8,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(0, 0, 0, alpha: 0.04), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )

    static let graphite = OpenLensTheme(
        id: "graphite",
        name: "Graphite",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(242, 244, 246), dark: .openLens(16, 18, 20)),
            surface: .init(light: .white, dark: .openLens(25, 28, 31)),
            primary: .init(light: .openLens(20, 26, 34), dark: .openLens(245, 247, 249)),
            secondary: .init(light: .openLens(100, 110, 122), dark: .openLens(160, 170, 181)),
            tertiary: .init(light: .openLens(232, 236, 240), dark: .openLens(38, 43, 48)),
            separator: .init(light: .openLens(216, 221, 226), dark: .openLens(58, 64, 70)),
            accent: .init(light: .openLens(42, 88, 103), dark: .openLens(146, 218, 204)),
            onAccent: .init(light: .white, dark: .openLens(13, 23, 25)),
            success: .init(light: .openLens(28, 134, 86), dark: .openLens(91, 205, 146)),
            warning: .init(light: .openLens(184, 113, 31), dark: .openLens(237, 172, 83)),
            danger: .init(light: .openLens(199, 55, 61), dark: .openLens(255, 119, 126))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(22, 32, 43, alpha: 0.08), dark: .openLens(0, 0, 0, alpha: 0.34)),
                radius: 9,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(22, 32, 43, alpha: 0.05), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )

    static let meadow = OpenLensTheme(
        id: "meadow",
        name: "Meadow",
        colors: OpenLensColorTokens(
            background: .init(light: .openLens(246, 247, 241), dark: .openLens(16, 22, 20)),
            surface: .init(light: .openLens(255, 255, 252), dark: .openLens(25, 33, 30)),
            primary: .init(light: .openLens(27, 33, 28), dark: .openLens(242, 247, 241)),
            secondary: .init(light: .openLens(94, 108, 92), dark: .openLens(164, 180, 166)),
            tertiary: .init(light: .openLens(235, 240, 231), dark: .openLens(36, 47, 42)),
            separator: .init(light: .openLens(220, 228, 216), dark: .openLens(55, 68, 61)),
            accent: .init(light: .openLens(28, 110, 80), dark: .openLens(114, 212, 161)),
            onAccent: .init(light: .white, dark: .openLens(11, 22, 16)),
            success: .init(light: .openLens(28, 128, 83), dark: .openLens(112, 216, 156)),
            warning: .init(light: .openLens(172, 112, 38), dark: .openLens(232, 174, 91)),
            danger: .init(light: .openLens(194, 62, 61), dark: .openLens(252, 126, 124))
        ),
        typography: OpenLensTypographyTokens(),
        spacing: OpenLensSpacingTokens(),
        radius: OpenLensRadiusTokens(),
        shadow: OpenLensShadowTokens(
            surface: OpenLensShadowStyle(
                color: .init(light: .openLens(30, 58, 42, alpha: 0.07), dark: .openLens(0, 0, 0, alpha: 0.32)),
                radius: 8,
                x: 0,
                y: 2
            ),
            subtle: OpenLensShadowStyle(
                color: .init(light: .openLens(30, 58, 42, alpha: 0.05), dark: .openLens(0, 0, 0, alpha: 0.24)),
                radius: 4,
                x: 0,
                y: 1
            )
        ),
        components: OpenLensComponentTokens()
    )
}

enum OpenLensDesignSystem {
    static var currentTheme: OpenLensTheme {
        OpenLensAppearance.fallback.theme
    }
}

// MARK: - Accent Color Preference

/// Global, persisted user accent color.
///
/// Stored in `UserDefaults` under `AppPreferenceKeys.accentColor` as a 6-digit hex string
/// (empty = use the theme accent). Because this is `@Observable`, any SwiftUI view that reads
/// `Color.appUserAccent` / `Color.appUserOnAccent` in its `body` is automatically re-rendered when
/// the user picks a new color. Scoped to the Settings screen, the chat bubble background, and the
/// message send button — everywhere else uses the fixed theme accent (`Color.appAccent`).
@Observable
final class AccentColorPreference {
    static let shared = AccentColorPreference()

    @ObservationIgnored private let userDefaults: UserDefaults

    /// Normalized `RRGGBB` hex, or empty when the theme default is used.
    private(set) var hex: String

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.hex = Self.normalizedHex(userDefaults.string(forKey: AppPreferenceKeys.accentColor)) ?? ""
    }

    var hasCustomColor: Bool { !hex.isEmpty }

    /// The accent color used across the app.
    var color: Color {
        guard let custom = Self.uiColor(fromHex: hex) else {
            return OpenLensDesignSystem.currentTheme.colors.accent.color
        }
        return Color(uiColor: custom)
    }

    /// Foreground color that stays readable on top of `color`.
    var onAccentColor: Color {
        guard let custom = Self.uiColor(fromHex: hex) else {
            return OpenLensDesignSystem.currentTheme.colors.onAccent.color
        }
        return Self.isLight(custom) ? Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255) : .white
    }

    /// Two-way binding for `ColorPicker`.
    var binding: Binding<Color> {
        Binding(
            get: { self.color },
            set: { self.setColor($0) }
        )
    }

    func setColor(_ color: Color) {
        guard let newHex = Self.hex(from: UIColor(color)) else { return }
        guard newHex != hex else { return }
        hex = newHex
        userDefaults.set(newHex, forKey: AppPreferenceKeys.accentColor)
    }

    func reset() {
        guard hasCustomColor else { return }
        hex = ""
        userDefaults.removeObject(forKey: AppPreferenceKeys.accentColor)
    }

    // MARK: Helpers

    static func normalizedHex(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, UInt32(value, radix: 16) != nil else { return nil }
        return value
    }

    static func uiColor(fromHex hex: String) -> UIColor? {
        guard let normalized = normalizedHex(hex), let value = UInt32(normalized, radix: 16) else {
            return nil
        }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hex(from color: UIColor) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func component(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", component(red), component(green), component(blue))
    }

    private static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.179
    }
}

private struct OpenLensThemeKey: EnvironmentKey {
    static let defaultValue: OpenLensTheme = OpenLensDesignSystem.currentTheme
}

extension EnvironmentValues {
    var openLensTheme: OpenLensTheme {
        get { self[OpenLensThemeKey.self] }
        set { self[OpenLensThemeKey.self] = newValue }
    }
}

private struct OpenLensThemeModifier: ViewModifier {
    let theme: OpenLensTheme
    private let accent = AccentColorPreference.shared

    func body(content: Content) -> some View {
        content
            .environment(\.openLensTheme, theme)
            .environment(accent)
            .tint(theme.colors.accent.color)
    }
}

extension View {
    func openLensTheme(_ theme: OpenLensTheme) -> some View {
        modifier(OpenLensThemeModifier(theme: theme))
    }
}

extension Color {
    static var appBackground: Color { OpenLensDesignSystem.currentTheme.colors.background.color }
    static var appSurface: Color { OpenLensDesignSystem.currentTheme.colors.surface.color }
    static var appPrimary: Color { OpenLensDesignSystem.currentTheme.colors.primary.color }
    static var appSecondary: Color { OpenLensDesignSystem.currentTheme.colors.secondary.color }
    static var appTertiary: Color { OpenLensDesignSystem.currentTheme.colors.tertiary.color }
    static var appSeparator: Color { OpenLensDesignSystem.currentTheme.colors.separator.color }
    static var appAccent: Color { OpenLensDesignSystem.currentTheme.colors.accent.color }
    static var appOnAccent: Color { OpenLensDesignSystem.currentTheme.colors.onAccent.color }
    /// User-selected accent (Settings → Appearance) or the theme accent, scoped to the Settings
    /// screen, the chat bubble background, and the message send button. Observable: views reading
    /// this in `body` refresh automatically when the preference changes.
    static var appUserAccent: Color { AccentColorPreference.shared.color }
    static var appUserOnAccent: Color { AccentColorPreference.shared.onAccentColor }
    static var appSuccess: Color { OpenLensDesignSystem.currentTheme.colors.success.color }
    static var appWarning: Color { OpenLensDesignSystem.currentTheme.colors.warning.color }
    static var appDanger: Color { OpenLensDesignSystem.currentTheme.colors.danger.color }
}

// MARK: - Surface Shadow

private struct OpenLensShadowModifier: ViewModifier {
    @Environment(\.openLensTheme) private var theme

    let style: KeyPath<OpenLensShadowTokens, OpenLensShadowStyle>

    func body(content: Content) -> some View {
        let shadow = theme.shadow[keyPath: style]
        content.shadow(
            color: shadow.color.color,
            radius: shadow.radius,
            x: shadow.x,
            y: shadow.y
        )
    }
}

extension View {
    func surfaceShadow() -> some View {
        modifier(OpenLensShadowModifier(style: \.surface))
    }

    func subtleShadow() -> some View {
        modifier(OpenLensShadowModifier(style: \.subtle))
    }
}
