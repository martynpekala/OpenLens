# OpenLens Design System

OpenLens uses a theme-driven design system defined in
`OpenLens/Views/Components/DesignTokens.swift`.

## Theme Model

- `OpenLensAppearance` is the built-in preset list. The app currently ships with a fixed fallback appearance and no user-facing theme switcher.
- `OpenLensTheme` groups color, typography, spacing, radius, shadow, and component tokens.
- `OpenLensComponentTokens` includes opt-in border tokens for surfaces, controls, and icon tiles. These default to zero-width strokes for the current app look, but allow a future high-contrast framed theme without custom card views.
- `OpenLensApp` injects the active theme with `.openLensTheme(...)`.
- Existing `Color.app...` semantic colors are compatibility accessors that resolve through the active appearance.

## Adding A New Look

1. Add a case to `OpenLensAppearance`.
2. Add `displayName` and `subtitle`.
3. Add a matching `OpenLensTheme` preset.
4. Set component stroke tokens when the look needs framed panels, inset borders, or outlined icon tiles.
5. Return that preset from `OpenLensAppearance.theme`.

Keep new presets registered in `OpenLensAppearance.allCases`, but expose a picker only when theme switching is ready for users again.

There is intentionally no Game Boy Color or Pokemon-inspired appearance registered yet.
The current design system is prepared for that future theme through semantic colors,
theme typography, radius tokens that can be reduced to square corners, and component
border tokens consumed by the base surface components.

## Usage Rules

- Prefer semantic colors such as `Color.appBackground`, `Color.appSurface`, `Color.appPrimary`, and `Color.appAccent`.
- In reusable components, read `@Environment(\.openLensTheme)` and use tokens directly.
- Prefer `SurfaceCard`, `SurfaceIconTile`, `SurfaceDivider`, and `SectionLabel` for standard app surfaces.
- Keep one-off visual constants local only when they express data state, not brand or layout style.
