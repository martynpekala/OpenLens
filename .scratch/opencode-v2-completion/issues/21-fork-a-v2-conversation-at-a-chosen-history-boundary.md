# 21: Fork a V2 conversation at a chosen history boundary

**What to build:** Explore a second approach by forking supported conversation history and opening the resulting session.

**Blocked by:** 01: Preserve canonical V2 session model, variant, and agent.

**Status:** ready-for-agent

**Priority:** P2

- [ ] The user can fork before a supported message boundary or copy the supported full settled history.
- [ ] The exclusive before boundary and separate fork lineage metadata are preserved.
- [ ] The fork appears in the session catalog even when parentID is absent.
- [ ] Current inherited model, variant, agent, and supported settings remain authoritative instead of being reconstructed historically.
- [ ] The UI explains that conversation forking shares files unless a separate worktree/location is explicitly selected.
- [ ] Remote checks the resulting session location and ownership before continuing work.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
