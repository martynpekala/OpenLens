import SwiftUI
import UIKit

// MARK: - Design Tokens

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
}

extension Color {
    /// Warm off-white / graphite — główne tło aplikacji
    static let appBackground = openLensDynamic(
        light: .openLens(245, 244, 242),
        dark: .openLens(20, 21, 24)
    )
    /// Powierzchnie kart i bąbelków AI
    static let appSurface = openLensDynamic(
        light: .white,
        dark: .openLens(30, 32, 36)
    )
    /// Główny kolor tekstu i ikon
    static let appPrimary = openLensDynamic(
        light: .openLens(26, 26, 26),
        dark: .openLens(245, 244, 242)
    )
    /// Ciepła szarość — subtitles, labele sekcji
    static let appSecondary = openLensDynamic(
        light: .openLens(107, 107, 107),
        dark: .openLens(171, 168, 161)
    )
    /// Tło inputu, chipów i nieaktywnych elementów
    static let appTertiary = openLensDynamic(
        light: .openLens(239, 237, 233),
        dark: .openLens(44, 46, 51)
    )
    /// Separator — delikatna linia
    static let appSeparator = openLensDynamic(
        light: .openLens(224, 222, 221),
        dark: .openLens(64, 66, 71)
    )
    /// Wyróżnione CTA i bąbelki użytkownika
    static let appAccent = openLensDynamic(
        light: .openLens(26, 26, 26),
        dark: .openLens(239, 237, 233)
    )
    /// Tekst i ikony na tle `appAccent`
    static let appOnAccent = openLensDynamic(
        light: .white,
        dark: .openLens(26, 26, 26)
    )
}

// MARK: - Surface Shadow

extension View {
    /// Delikatny cień dla kart (SurfaceCard, bąbelki AI)
    func surfaceShadow() -> some View {
        self.shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    /// Bardzo subtelny cień — dla elementów wewnątrz kart
    func subtleShadow() -> some View {
        self.shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}
