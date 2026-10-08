# 27: Diagnose unavailable models and MCP integrations

**What to build:** Inspect supported read-only integration and MCP status and understand the next available recovery action.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P3

- [ ] An existing settings/workspace entry exposes supported status with loading, failure, retry, and unsupported states.
- [ ] Model/provider availability and MCP connection status are distinguished without exposing raw credentials or configuration dumps.
- [ ] Supported authentication methods or required follow-up actions are intelligible without a full administration console.
- [ ] Status refresh updates dependent catalogs only after successful relevant changes.
- [ ] Remote defines an authorized status scope rather than treating global administrative routes as ordinary session operations.
- [ ] Tests cover connected, unavailable, authentication-required, and unauthorized states.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
