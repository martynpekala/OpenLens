# OpenLens

**iOS companion app for [OpenCode](https://opencode.ai) — chat with your AI coding assistant from your phone.**

<p align="leading">
  <a href="https://apps.apple.com/pl/app/openlens-opencode-client/id6759910797">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="50" />
  </a>
</p>

OpenLens connects to an OpenCode server running on your Mac and gives you a native iPhone and iPad interface to chat, review changes, browse workspace context, answer agent questions, and manage sessions away from the keyboard.

<p align="center">
  <img src="PromoScreenshots/0x0ss-2.png" width="220" alt="OpenLens promo screenshot 1" />
  <img src="PromoScreenshots/0x0ss-3.png" width="220" alt="OpenLens promo screenshot 2" />
  <img src="PromoScreenshots/0x0ss-4.png" width="220" alt="OpenLens promo screenshot 3" />
</p>

<p align="center">
  <img src="PromoScreenshots/0x0ss-5.png" width="220" alt="OpenLens promo screenshot 4" />
  <img src="PromoScreenshots/0x0ss-6.png" width="220" alt="OpenLens promo screenshot 5" />
  <img src="PromoScreenshots/0x0ss-7.png" width="220" alt="OpenLens promo screenshot 6" />
</p>

## Install

- **App Store**: install OpenLens on iPhone or iPad from the App Store using the badge above.
- **From source**: clone the repo, run `xcodegen generate`, then open the generated `OpenLens.xcodeproj` in Xcode 26 or newer.
- **Bundled tools**: `openlens-qr`, `openlens-qr-menubar`, and `appstore-shot-studio` are source-first helper tools included in this repository.

## Releases

- **iOS app releases**: the primary end-user distribution channel is the App Store.
- **Source builds**: contributors and self-hosters can build from `main` or from tagged revisions in Git.
- **Compatibility**: the repository currently targets iOS/iPadOS 26+ and current OpenCode server behavior on macOS.


## Features

- **Native session chat** — rich Markdown rendering, code blocks, thinking indicators, agent activity cards, permission prompts, and question flows
- **Flexible connection flows** — QR code scan, Bonjour auto-discovery, manual URL entry, saved servers, auto-reconnect, and `openlens://` deep links
- **Session management** — browse, create, delete, switch, and continue existing OpenCode sessions
- **Review tab** — inspect session-wide changes or a single agent update, open diffs, and revert one update without discarding the whole session
- **Workspace tab** — browse files, worktrees, slash commands, and changed files, then request branch switches, pushes, and pull requests through the active session
- **Inbox and insights** — answer pending questions, approve permissions, and inspect local cost, token usage, and model breakdowns for a session
- **Model controls** — switch between AI providers/models and available reasoning variants directly from the app
- **Live Activities** — track agent progress on your Lock Screen and Dynamic Island
- **Demo mode** — try the app without a server to see how it works
- **Setup wizard & onboarding** — guided first-launch experience
- **`openlens-qr` CLI tool** — generate a QR code from your terminal for instant phone connection
- **`openlens-qr-menubar` helper** — launch the QR flow from the macOS menu bar with a remembered workspace folder
- **`appstore-shot-studio` tool** — turn raw screenshots into App Store-ready promo images


## Quick Start

### 1. Install OpenCode on your Mac

```bash
curl -fsSL https://opencode.ai/install | bash
```

### 2. Start the server + show QR code (recommended)

Build and run the `openlens-qr` CLI tool included in this repo:

```bash
cd Tools/openlens-qr
xcrun swift build -c release
.build/release/openlens-qr --serve
```

This will:
1. Start an OpenCode server on port `4096`
2. Display a QR code in your terminal
3. Wait for you to scan it with OpenLens on your phone
4. Press Enter to open the TUI — now you have both desktop and mobile access

### 3. Open OpenLens on your iPhone and connect

- **Scan QR** — tap "Scan QR Code" and point at the terminal
- **Auto-discover** — tap "Tap to scan for nearby servers" (Bonjour; start OpenCode with `--mdns` if you want discovery)
- **Manual** — enter your Mac's IP and port (e.g. `192.168.1.50:4096`)

That's it. You're chatting with your AI coding assistant from your phone.


## `openlens-qr` CLI Reference

```
Usage: openlens-qr [server-url] [options]

Arguments:
  [server-url]          Server address (e.g. 192.168.1.50:4096)
                        Optional — auto-detected if omitted

Options:
  --serve, -s           Start OpenCode server, show QR when ready, then open TUI
  --port <number>       Port when using auto-detected IP (default: 4096)
  --user, -u <name>     Username (default: opencode)
  --print-secret-link   Print the full deep link, including password if set
  --help, -h            Show this help

Environment:
  OPENLENS_QR_PASSWORD  Optional password included in the QR deep link
                        and used for serve mode
```

**Examples:**

```bash
openlens-qr                              # auto-detect IP, show QR
openlens-qr --serve                      # QR + start server & TUI
OPENLENS_QR_PASSWORD=secret openlens-qr --serve
OPENLENS_QR_PASSWORD=secret openlens-qr --print-secret-link
openlens-qr 192.168.1.50:4096            # explicit address, QR only
```


## `openlens-qr-menubar`

Menubar helper for macOS that launches `openlens-qr --serve` in your default terminal app using a workspace folder you choose once and reuse later.

```bash
cd Tools/openlens-qr-menubar
./run-menubar.sh
```

What it does:

1. builds the menubar app with Tuist
2. opens a menu bar extra named `OpenLens QR`
3. lets you pick the folder where OpenCode should run
4. remembers the last selected folder
5. opens your default terminal app and runs `openlens-qr --serve` from that folder

Requirements:

- `tuist` installed locally for the menubar app build
- Xcode command line tools for `xcrun swift build`
- `opencode` installed and available in `PATH`


## `appstore-shot-studio`

Compose App Store visuals from raw screenshots:

```bash
cd Tools/appstore-shot-studio
python3 -m http.server 8080
```

Then open `http://localhost:8080` and:

1. drop in a screenshot
2. choose an App Store size preset
3. add one text line above the mockup and tune its position, font, weight, size, and background style
4. export a PNG


## Alternative: Manual Server Setup

If you prefer not to use the CLI tool, start the server yourself:

```bash
opencode serve --port 4096 --hostname 0.0.0.0
```

Then connect from the app using your Mac's local IP address.

If you want OpenLens to find the server via Bonjour, start OpenCode with `--mdns` as well.


## Requirements

- **iOS app**: iPhone or iPad with iOS/iPadOS 26+
- **Server**: macOS with [OpenCode](https://opencode.ai) installed
- **Network**: both devices on the same local network for QR, manual, or Bonjour-based setup


## Project Layout

- `OpenLens/` — main iOS app
- `OpenLensActivityWidget/` — Live Activity widget extension
- `OpenLensTests/` — unit tests
- `Tools/openlens-qr/` — Swift CLI for QR-based setup
- `Tools/openlens-qr-menubar/` — macOS menu bar launcher for the QR flow
- `Tools/appstore-shot-studio/` — local browser tool for App Store screenshots


## Development

- **Toolchain**: Xcode 26+, iOS 26 simulator/runtime, macOS, OpenCode installed locally
- **Project generation**: install XcodeGen with `brew install xcodegen`, then run `xcodegen generate`
- **Open the project**: the generated `OpenLens.xcodeproj`
- **Device signing**: if you want to run on your own device, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and replace the team, bundle identifiers, and App Group values with your own

Run the main verification command from the repository root:

If `iPhone 17` is not installed locally, swap the simulator name for any available iOS Simulator from `xcrun simctl list devices`.

```bash
xcodegen generate
xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
```

Build the bundled QR helper:

```bash
xcrun swift build --package-path Tools/openlens-qr
```


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and PR expectations, [SECURITY.md](SECURITY.md) for vulnerability reporting, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community guidelines.


## Support And Community

- **Bug reports**: open a GitHub issue with the bug report template and include a clear reproduction path.
- **Feature proposals**: open a GitHub issue with the feature request template when the request is concrete and actionable.
- **Security issues**: use GitHub Private Vulnerability Reporting and follow [SECURITY.md](SECURITY.md).
- **Questions and setup help**: use GitHub Discussions if enabled for this repository; otherwise open a documentation-focused issue only when something in the repo needs to change.


## OpenCode

This project is not built by the OpenCode team and is not affiliated with it in any way.


## Deep Links

OpenLens supports the `openlens://` URL scheme for automated connection:

```
openlens://connect?url=192.168.1.50:4096&user=opencode&pass=optional&sessionID=abc123
```

The `openlens-qr` tool encodes this into the QR code automatically.

If `sessionID` is present, OpenLens connects first and then opens that session automatically.


## License

This project is licensed under the [MIT License](LICENSE).
