# Contributing

Thanks for taking the time to improve OpenLens.

## Local Setup

- Use Xcode 26 or newer.
- Install XcodeGen (`brew install xcodegen`).
- Install OpenCode locally if you want to exercise real server flows.
- Run `xcodegen generate` from the repository root.
- Open the generated `OpenLens.xcodeproj` in Xcode.
- If you want to run on your own device, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and replace the signing team, bundle identifiers, and App Group values with your own.

## Project Layout

- `OpenLens/` - main iOS app
- `OpenLensActivityWidget/` - Live Activity widget extension
- `OpenLensWatchApp/` - Apple Watch app container
- `OpenLensWatchExtension/` - Apple Watch companion UI and logic
- `OpenLensTests/` - app tests

## Architecture Notes

- Do not introduce `ViewModel`, `VM`, or `Presenter` types.
- Inject shared services through `@Environment`.
- Keep view-local state in `@State`, preferably with enums for loading/error/loaded flows.
- Put business logic in `@Observable` services.
- Use Swift Testing for new tests.

The repository also includes additional architecture notes in `AGENTS.md` and `.opencode/skills/`.

## Verification

Run the main app tests from the repository root using Python 3, XcodeGen, and the selected Xcode command-line tools:

```bash
./scripts/test-ios.sh
```

The script generates the project, builds for testing, and runs the full suite on the local `iPhone 18 Pro` (`F323E9E4-4B39-4EB6-A42B-AB9E203A3E9A`). To use another installed simulator, pass `--simulator <UDID>` from `xcrun simctl list devices`.

For focused iteration:

```bash
./scripts/test-ios.sh --only-testing OpenLensTests/V2SessionInboxTests
# Reuse this build only while the source remains unchanged:
./scripts/test-ios.sh --skip-build --only-testing OpenLensTests/V2SessionInboxTests
```

Finish verification with a full-suite run. Keep Xcode's test action idle on the selected simulator while the script runs. A lock per simulator prevents overlapping script runs across agents, terminals, and worktrees; it releases automatically when the runner exits.

The default limits are 600 seconds for project generation/building, 90 seconds per simulator operation, and 120 seconds per test invocation. Override them with `--build-timeout`, `--simulator-timeout`, or `--test-timeout` followed by seconds. The limits cover the entire command, including application launch. On timeout or interruption, the script stops its own command process group.

An application launch failure or a timeout before tests begin triggers a simulator shutdown, a wait for boot readiness, and one retry without rebuilding. Assertion failures and timeouts after tests begin fail verification immediately. A second startup failure also fails verification. Successful runs leave the simulator booted.

Each run prints its directory under `build/test-runs/`, containing command logs and a separate `.xcresult` bundle for each test attempt when Xcode produces one. Preserve the first attempt when reporting recovery or failure. This directory is ignored by Git. Run `./scripts/test-ios.sh --help` for all options.

## Pull Requests

- Keep PRs focused and explain the user-facing reason for the change.
- Include screenshots for visible UI changes.
- Note the test commands you ran.
- Call out any areas you could not verify.
- Do not commit secrets, signing material, or local editor/workspace files.
