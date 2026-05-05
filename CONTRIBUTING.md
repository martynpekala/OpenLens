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
- `Tools/openlens-qr/` - Swift CLI for QR-based setup
- `Tools/appstore-shot-studio/` - local browser tool for marketing screenshots

## Architecture Notes

- Do not introduce `ViewModel`, `VM`, or `Presenter` types.
- Inject shared services through `@Environment`.
- Keep view-local state in `@State`, preferably with enums for loading/error/loaded flows.
- Put business logic in `@Observable` services.
- Use Swift Testing for new tests.

The repository also includes additional architecture notes in `AGENTS.md` and `.opencode/skills/`.

## Verification

Run the main app tests from the repository root:

If `iPhone 17` is not installed locally, replace the simulator name with any available iOS Simulator from `xcrun simctl list devices`.

```bash
xcodegen generate
xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
```

Build the QR helper when you touch the CLI:

```bash
xcrun swift build --package-path Tools/openlens-qr
```

If you change `Tools/appstore-shot-studio/`, open `Tools/appstore-shot-studio/index.html` locally or serve the folder and verify the changed flow in a browser.

## Pull Requests

- Keep PRs focused and explain the user-facing reason for the change.
- Include screenshots for visible UI changes.
- Note the test commands you ran.
- Call out any areas you could not verify.
- Do not commit secrets, signing material, or local editor/workspace files.
