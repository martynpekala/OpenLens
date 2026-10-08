# 07: Mark newly completed V2 session results as unread

**What to build:** Find results completed while away and mark only the observed completion as viewed.

**Blocked by:** 06: Show authoritative V2 execution outcomes.

**Status:** ready-for-agent

**Priority:** P2

- [ ] Idle and viewed markers determine whether a completed result is unread in the session list.
- [ ] Viewing sends the supported operation with the observed idle marker rather than a blanket mark-all-read mutation.
- [ ] A newer completion arriving during viewing remains unread.
- [ ] Failed view acknowledgement is reconciled rather than silently persisted as server-confirmed.
- [ ] The behavior stays accurate after refresh and across desktop/phone viewing.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
