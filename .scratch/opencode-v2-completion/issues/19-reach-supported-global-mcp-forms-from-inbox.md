# 19: Reach supported global MCP forms from Inbox

**What to build:** Discover and complete supported global MCP form interactions without inventing a normal session owner.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] Global ownership is represented separately from ordinary session ownership in the existing Inbox flow.
- [ ] Supported global forms can be recovered, answered, and cancelled using their documented ownership contract.
- [ ] Opening another chat does not hide or misroute the global interaction.
- [ ] Remote permits only the defined global form operations and retains ordinary session ownership checks.
- [ ] Unsupported field semantics retain the existing safe fallback; conditional support can arrive independently.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
