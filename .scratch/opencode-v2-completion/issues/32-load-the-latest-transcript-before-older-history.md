# 32: Load the latest transcript before older history

**What to build:** Continue a long conversation after loading its latest available page, then retrieve older timeline entries on demand.

**Blocked by:** 10: Preserve useful V2 context changes in the timeline.

**Status:** ready-for-agent

**Priority:** P2

- [ ] The supported latest-page traversal produces useful initial content without collecting the complete transcript.
- [ ] Older pages preserve full timeline identity/order, including contextual entries, and preserve scroll position when prepended.
- [ ] Live events and paged history reconcile without duplicating messages, tools, or context rows.
- [ ] Loading/error/end-of-history states remain explicit and repeated or invalid cursors are rejected.
- [ ] Current session settings and current outcomes are recovered independently of whichever history page is visible.
- [ ] Complete analytics sources remain separate from the loaded UI slice.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
