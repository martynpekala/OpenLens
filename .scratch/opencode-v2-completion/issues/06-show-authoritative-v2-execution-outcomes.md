# 06: Show authoritative V2 execution outcomes

**What to build:** Show the actual result and current execution state instead of interpreting an absent active-session entry as success.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] Canonical session outcome and idle time survive decoding and refresh and are visible in existing session/chat presentation.
- [ ] Succeeded, failed, and interrupted outcomes remain distinct from active work and pending permissions/forms.
- [ ] A completed assistant step does not finish the entire session while server execution continues.
- [ ] An absent active entry with incomplete outcome evidence is not labeled successful.
- [ ] Stream gaps and foreground refresh restore the outcome without applying stale results to another session.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
