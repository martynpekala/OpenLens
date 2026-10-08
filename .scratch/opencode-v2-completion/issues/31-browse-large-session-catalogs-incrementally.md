# 31: Browse large session catalogs incrementally

**What to build:** Browse a large session catalog using supported paging, search, and filters while retaining truthful coverage.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] Initial display fetches a useful supported page and loads further pages on demand.
- [ ] Server-supported search and filters use their documented semantics without client-only full-catalog loading.
- [ ] Root filtering and initially filtered/empty pages do not prematurely report a complete empty result.
- [ ] Duplicate, missing, invalid, and repeated continuation cursors cannot cause silent partial success or an infinite loop.
- [ ] Insights/calendar retain a separate complete source or explicitly identified coverage rather than inheriting the partial UI list.
- [ ] Direct and Remote catalogs retain canonical-location isolation.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
