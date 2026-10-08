# 08: Rebind an open V2 session after its location changes

**What to build:** Continue an already open session in its authoritative new location after a move made by another client.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] Canonical location changes trigger restoration of project context and refresh location-dependent files and catalogs.
- [ ] Event filters and subsequent location-dependent requests use the new canonical directory.
- [ ] Late responses from the old location cannot overwrite the rebound workspace.
- [ ] A failed or unauthorized rebind remains explicit and does not forward work to an unapproved location.
- [ ] A two-client move while the chat is open is verified directly and through Remote.
- [ ] This ticket observes external moves; initiating a move from the phone is a separate slice.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
