# 22: Move a V2 session to another approved location

**What to build:** Request a session move to an available approved destination and follow its pending and applied states.

**Blocked by:** 03: Restore the shared V2 session inbox after reconnecting; 08: Rebind an open V2 session after its location changes.

**Status:** ready-for-agent

**Priority:** P2

- [ ] The user can choose an available destination and admit the supported move control operation.
- [ ] The shared inbox shows the pending move and the location changes only after canonical server confirmation.
- [ ] The existing rebind flow updates catalogs, files, filtering, and subsequent requests after application.
- [ ] Remote checks both current session ownership and destination approval, including registry revocation.
- [ ] The UI does not imply that moving a session copies files or applies immediately during an active step.
- [ ] Reconnect, move failure, and competing-client changes retain accurate session state.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
