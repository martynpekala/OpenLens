# 05: Use V2 skills through Remote

**What to build:** Load and use the V2 skill catalog through Remote with the same useful behavior as a direct connection.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] The exact skill-list GET operation is allowed for a canonical approved location and retains existing V1 routes.
- [ ] The skill catalog and mention UI are available for the approved workspace through direct and Remote connections.
- [ ] An empty catalog is distinguishable from a rejected, unavailable, or failed request and offers an appropriate retry.
- [ ] Foreign, ambiguous, or unapproved locations remain rejected without broad API-prefix forwarding.
- [ ] Gateway and service behavior tests cover successful loading, failure presentation, and isolation.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
