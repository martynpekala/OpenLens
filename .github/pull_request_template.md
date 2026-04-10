## Why

Explain the user-facing reason for this change.

## What Changed

-

## Verification

- [ ] `xcodegen generate`
- [ ] `xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test`
- [ ] `xcrun swift build --package-path Tools/openlens-qr` (if CLI code changed)
- [ ] Browser flow checked for `Tools/appstore-shot-studio/` changes

## Screenshots

Attach screenshots or recordings for visible UI changes when relevant.

## Risks

Call out migration, networking, or UX risks if any.
