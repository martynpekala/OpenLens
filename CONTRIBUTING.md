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

### Multi-server

OpenLens holds several OpenCode servers connected at once. Three commands gate a
release:

```bash
./scripts/test-ios.sh                                                # full suite
./scripts/test-ios.sh --only-testing OpenLensTests/MultiServerSuite  # the feature, named
./scripts/verify-ui-parity.sh                                        # single-server pixel parity
```

The second is redundant with the first by construction. It is there so a release
can report "multi-server: N tests passed" instead of inferring it from a
900-test run, and so a regression is attributable at a glance. Narrow it further
while iterating, e.g.
`--only-testing OpenLensTests/MultiServerSuite/Aggregation`.

`verify-ui-parity.sh` captures the fixture screens and compares the
single-server ones against the baselines committed in
`.interface-design/baselines/`. It exists because the rule it checks — with one
saved server the app looks exactly as it did before multi-server — is a claim
about pixels that no unit test can make. Two layout regressions reached a green
suite and were caught only here. It needs a build, so run `test-ios.sh` first,
and it takes the same simulator lock, so do not run them at once.

A difference under tolerance in one band is the sessions list's animating busy
row. More than one band, or a band elsewhere, is a layout shift. A very large
difference usually means the capture is of the wrong screen rather than a real
change. Regenerate baselines with `--update-baselines` only for a deliberate,
reviewed design change.

Three standing invariants, each with the suite that owns it: a single saved
server produces byte-identical UI (`MultiServerSuite/SingleServerParity`); the
tab-bar hiding predicate is untouched (`ConnectedRootTabBarVisibilityTests`,
which must stay green with zero edits); and no server's client ever reaches
another server's transport (`MultiServerSuite/Registry`, via recorded routes).

#### Two real servers

What no unit test covers. Run two servers on different ports
(`opencode serve --port 4096 --hostname 0.0.0.0` and `--port 4097`), add both,
then confirm:

1. both reach connected, each with its own status dot;
2. the sessions list shows both servers' sessions, each section tagged;
3. opening a session on the non-active server switches to it and loads *that*
   server's transcript, slash catalog and skills;
4. switching away and back restores the previously open session;
5. the toolbar capsule reads *server · workspace* and its menu switches servers;
6. a permission prompt on the **non-active** server raises a Live Activity whose
   Allow button reaches **that** server;
7. background and foreground reconnects both, staggered, with no duplicate or
   cross-killed activities;
8. stopping one server degrades only its section; the rest stay usable;
9. a server beyond the connection cap refuses with a legible message and stays
   saved;
10. deleting a server leaves the other untouched, and once one remains every
    multi-server affordance disappears.

Steps 3, 6 and 7 are the ones unit tests reach least: they span a server switch,
a process boundary and a suspend/resume.

## Pull Requests

- Keep PRs focused and explain the user-facing reason for the change.
- Include screenshots for visible UI changes.
- Note the test commands you ran.
- Call out any areas you could not verify.
- Do not commit secrets, signing material, or local editor/workspace files.
