# 17: Request compaction and inspect the resulting summary

**What to build:** Request supported compaction from the context view, observe its inbox/timeline lifecycle, and inspect the resulting context.

**Blocked by:** 03: Restore the shared V2 session inbox after reconnecting; 10: Preserve useful V2 context changes in the timeline; 16: Inspect the active V2 session context.

**Status:** ready-for-agent

**Priority:** P2

- [ ] The supported compaction operation is admitted from the context view without pretending completion is synchronous.
- [ ] Its pending control entry is visible in the shared inbox and its result is visible in the timeline.
- [ ] Success refreshes active context and exposes the summary; failure or interruption remains distinguishable.
- [ ] Reopening or reconnecting restores the pending/completed state without submitting a second compaction.
- [ ] Unsupported installations expose an unavailable state instead of a failing active control.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
