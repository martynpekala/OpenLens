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

## Navigation Behavior
- Keep Chat tab bar hiding on `ConnectedRootView.tabNavigationView(for:)`'s `NavigationStack`. Do not move the `.toolbar(..., for: .tabBar)` modifier into `SessionChatDestinationView` or `ChatView`; that regresses tab bar hiding when entering a chat session.

## Skill Usage
- Project-local skills live in `.opencode/skills/` and are available to OpenCode in this repo.
- Use `swiftui-ui-patterns` for new UI, screen composition, navigation, sheets, tabs, lists, forms, and state ownership decisions.
- Use `swiftui-view-refactor` when cleaning up large SwiftUI files, extracting subviews, removing inline side effects, or simplifying data flow.
- Use `swiftui-liquid-glass` when implementing or reviewing iOS 26+ Liquid Glass APIs.
- Use `swiftui-performance-audit` when diagnosing janky scrolling, excessive updates, hangs, layout thrash, or other SwiftUI runtime performance issues.
- Use `appstore-screenshot-plan` when planning which screens to capture, writing marketing headlines, or configuring visual parameters for App Store screenshot compositions.
- Use `appstore-screenshot-capture` when building and running the app in screenshot mode, navigating through screens, taking raw simulator screenshots, and compositing them in appstore-shot-studio.
- Use `ios-appstore-audit` when preparing the app for App Store submission, checking for rejection risks, verifying privacy manifests, concurrency issues, IPv6 compliance, StoreKit integration, or detecting private API usage.
- Load a skill only when it is relevant to the task; do not preload skills just because they are available.
- Load multiple skills only when the task genuinely spans multiple areas.

## Verification
- When app or widget code changes, run `xcodegen generate && xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test` from the repo root.
- Use the local `iPhone 17 Pro` simulator for OpenLens verification unless the user explicitly asks for another destination.
- When `Tools/openlens-qr/` changes, run `xcrun swift build --package-path Tools/openlens-qr`.
- When `Tools/appstore-shot-studio/` changes, open `Tools/appstore-shot-studio/index.html` locally or serve the folder and verify the changed flow in a browser.

## Collaboration Notes
- Keep changes focused on the user-facing reason for the task.
- Include screenshots for visible UI changes.
- Do not commit secrets, signing material, or local editor/workspace files.
