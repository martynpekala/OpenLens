# 33: Use verified V2 statistics for Insights and the activity calendar

**What to build:** Load supported server activity/usage aggregates for Insights and the calendar without requiring every transcript.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P3

- [ ] Experimental stats are used only when availability and each displayed metric's meaning have been verified.
- [ ] Date range, project scope, timezone, and coverage are preserved and visible.
- [ ] Usage, cost, activity, and tool-reliability aggregates are not silently treated as interchangeable with previous calculations.
- [ ] A fixture set compares supported aggregates with complete history for known sessions and timezone boundaries.
- [ ] Missing support or errors use a truthful complete fallback or explicitly partial view.
- [ ] Remote restricts aggregate visibility to authorized scope rather than leaking foreign projects.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
