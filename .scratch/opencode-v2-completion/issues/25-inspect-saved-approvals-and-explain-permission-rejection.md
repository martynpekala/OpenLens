# 25: Inspect saved approvals and explain permission rejection

**What to build:** Control the lifetime and scope of supported saved permission rules and add feedback to a current rejection.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] The authorized saved-rule list presents action, resource, effect, and meaningful ordered scope.
- [ ] A user can remove a supported saved rule and refresh the resulting effective view.
- [ ] The current reject flow can submit an optional supported feedback message without changing request ownership.
- [ ] V1 and existing once/always/reject behavior remain intact.
- [ ] Remote policy does not expose global administrative authority merely because one session is visible.
- [ ] Rule removal, failure recovery, rejection feedback, and scope enforcement are exercised through services and gateway.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
