# OpenLens Project Rules

## Project Context
- OpenLens is a native iOS companion app for OpenCode.
- Main code lives in `OpenLens/`, `OpenLensActivityWidget/`, `OpenLensTests/`, `Tools/openlens-qr/`, and `Tools/appstore-shot-studio/`.
- Prefer existing local patterns over introducing new architectural layers.

## Architecture Defaults
- Do not introduce `ViewModel`, `VM`, or `Presenter` types.
- Inject shared services through `@Environment`.
- Keep view-local state in `@State`, preferably with enums for loading, error, and loaded flows.
- Put business logic in `@Observable` services.
- Use Swift Testing for new tests.

## Skill Usage
- Project-local skills live in `.opencode/skills/` and are available to OpenCode in this repo.
- Use `swiftui-ui-patterns` for new UI, screen composition, navigation, sheets, tabs, lists, forms, and state ownership decisions.
- Use `swiftui-view-refactor` when cleaning up large SwiftUI files, extracting subviews, removing inline side effects, or simplifying data flow.
- Use `swiftui-liquid-glass` when implementing or reviewing iOS 26+ Liquid Glass APIs.
- Use `swiftui-performance-audit` when diagnosing janky scrolling, excessive updates, hangs, layout thrash, or other SwiftUI runtime performance issues.
- Load a skill only when it is relevant to the task; do not preload skills just because they are available.
- Load multiple skills only when the task genuinely spans multiple areas.

## Verification
- When app or widget code changes, run `xcodegen generate && xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test` from the repo root.
- If `iPhone 17` is unavailable locally, swap in any installed iOS Simulator.
- When `Tools/openlens-qr/` changes, run `xcrun swift build --package-path Tools/openlens-qr`.
- When `Tools/appstore-shot-studio/` changes, open `Tools/appstore-shot-studio/index.html` locally or serve the folder and verify the changed flow in a browser.

## Collaboration Notes
- Keep changes focused on the user-facing reason for the task.
- Include screenshots for visible UI changes.
- Do not commit secrets, signing material, or local editor/workspace files.
