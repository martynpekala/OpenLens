import CoreGraphics
import Foundation
import Testing
@testable import OpenLens

struct DesignSystemThemeTests {

    @Test func appearancesExposeMatchingThemeIdentity() {
        let appearances = OpenLensAppearance.allCases
        let themeIDs = Set(appearances.map { $0.theme.id })

        #expect(themeIDs.count == appearances.count)

        for appearance in appearances {
            #expect(appearance.theme.id == appearance.id)
            #expect(!appearance.displayName.isEmpty)
            #expect(!appearance.subtitle.isEmpty)
            #expect(!appearance.theme.name.isEmpty)
        }
    }

    @Test func builtInThemesKeepFramedSurfacesOptIn() {
        for appearance in OpenLensAppearance.allCases {
            let components = appearance.theme.components

            #expect(components.surfaceBorder.width == 0)
            #expect(components.surfaceInnerBorder.width == 0)
            #expect(components.controlBorder.width == 0)
            #expect(components.iconTileBorder.width == 0)
        }
    }

    @Test func activeThemeUsesFallbackWhileAppearanceSwitchingIsDisabled() {
        let previousValue = UserDefaults.standard.string(forKey: OpenLensAppearance.storageKey)
        UserDefaults.standard.set(OpenLensAppearance.graphite.rawValue, forKey: OpenLensAppearance.storageKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: OpenLensAppearance.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: OpenLensAppearance.storageKey)
            }
        }

        #expect(OpenLensDesignSystem.currentTheme.id == OpenLensAppearance.fallback.id)
    }
}
