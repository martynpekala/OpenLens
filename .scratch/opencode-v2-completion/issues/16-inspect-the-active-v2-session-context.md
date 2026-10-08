# 16: Inspect the active V2 session context

**What to build:** Inspect the supported active-context projection separately from historical conversation and usage totals.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] A native context view reads the current server projection and presents loading, failure, retry, and unavailable states.
- [ ] Active context and full history are clearly distinguished and refreshed for the selected session.
- [ ] Any occupancy indication uses supported current data and an applicable model limit; cumulative historical tokens are never substituted.
- [ ] Unavailable or insufficient occupancy data is shown as unknown rather than a fabricated percentage.
- [ ] Context reads are location/session scoped through Remote and stale results are rejected.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
