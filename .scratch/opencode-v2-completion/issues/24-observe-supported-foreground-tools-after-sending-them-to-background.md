# 24: Observe supported foreground tools after sending them to background

**What to build:** Continue a supported active foreground tool in server background mode and inspect its state and bounded output.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] The background action is offered for supported foreground work and uses the documented server operation.
- [ ] State and output can be read through bounded supported operations with retry and pagination where available.
- [ ] An unsupported transition or idle no-op is not presented as a successfully detached running process.
- [ ] Server background work is distinguishable from the app being active or suspended on iOS.
- [ ] Remote provides exact authorized HTTP/SSE operations without adding a full PTY WebSocket channel.
- [ ] Reconnect restores supported process observation without repeating the background mutation.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
