# 11: Deliver background subagent results to the parent history

**What to build:** Read background child results in the parent timeline and reconcile the associated delegated-work card.

**Blocked by:** 09: Show running and completed V2 subagent tools; 10: Preserve useful V2 context changes in the timeline.

**Status:** ready-for-agent

**Priority:** P1

- [ ] Synthetic entries with the supported subagent source retain child ID, agent, result state, and useful result text.
- [ ] Completed, failed, and cancelled results are visible before any subsequent assistant response.
- [ ] The child card state and synthetic result are reconciled by stable identity rather than duplicate notifications.
- [ ] Results recover from REST history after a missed event or reopening the chat.
- [ ] Synthetic entries from unrelated or unknown sources are handled without being mistaken for a successful child result.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
