# 23: Open child sessions from delegated-work cards

**What to build:** Inspect a delegated child's conversation and interactions while preserving a clear route back to the parent.

**Blocked by:** 09: Show running and completed V2 subagent tools.

**Status:** ready-for-agent

**Priority:** P2

- [ ] A validated child identifier on a delegated-work card opens the actual child session.
- [ ] Child sessions remain reachable even when root-session filtering hides them from the primary catalog.
- [ ] The child's own location and supported state are restored and parent navigation remains available.
- [ ] Pending permissions/forms are answered using their actual child owner rather than the parent.
- [ ] Missing, deleted, or unauthorized children have useful failure states and do not navigate to unrelated work.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
