# 30: Export a session when the server supports it

**What to build:** Archive or share the supported exported session artifact without implying a public session link.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P3

- [ ] Export is offered only after support for the experimental contract is established.
- [ ] A successful export creates a usable artifact for the existing native save/share flow.
- [ ] Unavailable, failed, interrupted, and unauthorized exports have distinct recoverable states.
- [ ] The gateway authorizes the actual exported session and does not widen experimental routes generally.
- [ ] A saved artifact is read back and checked against the selected session; import and public sharing are outside this slice.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
