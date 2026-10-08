# 26: Make staged revert understandable and reversible

**What to build:** Choose the supported rollback scope and recover from a staged revert before it is committed.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] The user can distinguish history-only revert from a revert that affects the working directory.
- [ ] The UI explains that staging with files enabled can already change files rather than presenting it as a read-only preview.
- [ ] Clear restores a supported staged rollback, while commit and new-prompt transitions reconcile canonical state.
- [ ] Partial failures refresh the session and file changes before presenting the result.
- [ ] Existing one-tap revert remains coherent and V1 behavior stays supported.
- [ ] A controlled Git workspace verifies file effects, clear/commit behavior, and Remote ownership.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
