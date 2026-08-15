# OpenLens Remote

Native macOS menu-bar agent for encrypted access from OpenLens outside the
local network. The folder keeps its historical name, but the product and bundle
are `OpenLensRemote` / `dev.openlens.remote`.

The public hostname must be protected by Cloudflare Access Service Auth. The
agent validates the Access JWT at the loopback gateway and will not expose a
legacy or bypass mode.

Development build and tests:

```sh
tuist generate --no-open
xcodebuild -workspace OpenLensRemote.xcworkspace \
  -scheme OpenLensRemote \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Release builds must embed the pinned `cloudflared`, then be signed and
notarized. See `Scripts/build-release.sh` and
`../../OpenLens/Playbook/REMOTE_ACCESS_RUNBOOK.md`.
