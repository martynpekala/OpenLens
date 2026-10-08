# 09: Show running and completed V2 subagent tools

**What to build:** Identify delegated work across V1 task tools and V2 subagent tools and preserve the actual child execution state.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] Both legacy task and released V2 subagent names produce the existing delegated-work presentation.
- [ ] Validated session identifiers and supported status metadata survive safety preparation.
- [ ] A successful tool launch with running child metadata remains marked as running.
- [ ] Unknown or malformed metadata safely degrades without invalidating the tool or transcript.
- [ ] Existing permission/form relationships remain tied to the correct child session.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
