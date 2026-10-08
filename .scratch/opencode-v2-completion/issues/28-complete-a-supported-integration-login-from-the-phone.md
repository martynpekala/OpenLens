# 28: Complete a supported integration login from the phone

**What to build:** Finish a documented supported URL-based integration authentication attempt from the diagnostic view.

**Blocked by:** 27: Diagnose unavailable models and MCP integrations.

**Status:** ready-for-agent

**Priority:** P3

- [ ] The user can choose an available supported method and follow its documented attempt URL.
- [ ] Pending, successful, failed, and expired attempts are reconciled through the supported status contract.
- [ ] Successful completion refreshes the relevant integration and model catalogs.
- [ ] Provider credentials remain separate from server pairing and Remote device credentials and are not logged.
- [ ] Unsupported methods remain explicit; native/global forms use their dedicated form flows rather than guessed callbacks.
- [ ] A controlled supported authentication flow is demonstrated directly and through the authorized Remote policy.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
