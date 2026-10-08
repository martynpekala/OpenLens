# OpenLens Project Rules

## Project Context
- OpenLens is a native iOS companion app for OpenCode.
- Main code lives in `OpenLens/`, `OpenLensActivityWidget/`, and `OpenLensTests/`.
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
- Use `appstore-screenshot-capture` when building and running the app in screenshot mode, navigating through screens, taking raw simulator screenshots.
- Use `ios-appstore-audit` when preparing the app for App Store submission, checking for rejection risks, verifying privacy manifests, concurrency issues, IPv6 compliance, StoreKit integration, or detecting private API usage.
- Load a skill only when it is relevant to the task; do not preload skills just because they are available.
- Load multiple skills only when the task genuinely spans multiple areas.

## Verification
- When app, widget, or test code changes, run `./scripts/test-ios.sh` from the repo root. It generates the project, builds for testing, and runs the full suite with bounded waits, a simulator lock, and one startup recovery attempt.
- For focused iteration, use `./scripts/test-ios.sh --only-testing OpenLensTests/<Suite>`; add `--skip-build` only when the build already includes all current source changes. Finish with a full-suite run. See `CONTRIBUTING.md`'s Verification section for timeout options and log locations.
- Route command-line test runs through this script and keep Xcode's test action idle on the same simulator. The lock coordinates cooperating scripts across agents, terminals, and worktrees.
- The script preserves failed attempts and retries only startup failures before tests begin. Report assertion failures, execution timeouts after tests begin, or an exhausted recovery attempt as failed verification, with the saved log/result bundle; resolve the failure before rerunning.
- Keep the simulator booted between successful runs. Recovery stops only the script's own command processes and restarts the selected simulator.
- Tests are hosted in the iOS app, so they cannot run without a simulator unless the app is signed for "My Mac (Designed for iPad)".
- Use the local booted `iPhone 18 Pro` simulator (`F323E9E4-4B39-4EB6-A42B-AB9E203A3E9A`) for OpenLens verification unless the user explicitly asks for another destination.

## Collaboration Notes
- Keep changes focused on the user-facing reason for the task.
- Include screenshots for visible UI changes.
- Do not commit secrets, signing material, or local editor/workspace files.
- After marking an OpenCode V2 completion ticket done, add an entry to `.scratch/opencode-v2-completion/ENABLED.md` describing what the ticket now lets the user do, with its commits.
