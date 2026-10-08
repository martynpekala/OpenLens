# 29: Review branch and committed changes with an explicit base

**What to build:** Inspect supported branch/committed comparison modes in the existing Review experience.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P3

- [ ] The user can select supported comparison modes and an applicable explicit base.
- [ ] Mode, base, canonical location, and empty-result coverage remain visible.
- [ ] Stale responses from another comparison or workspace cannot replace the active selection.
- [ ] Unsupported installations keep existing turn/session/working-tree review usable.
- [ ] Diff loading, base errors, mode switching, and Remote authorization are verified.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
