# 10: Preserve useful V2 context changes in the timeline

**What to build:** Understand session context changes through compact, ordered timeline entries alongside the existing conversation.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] Supported model, agent, location, system, skill, shell, compaction, and idle entries retain stable identity and order.
- [ ] Useful entries appear as compact contextual rows or inspectable results without being fabricated as user/assistant messages.
- [ ] The existing chat-role model remains usable while transcript presentation can retain non-chat entries.
- [ ] History refresh and live projection converge without duplicate context rows.
- [ ] Unknown entry kinds do not invalidate an otherwise usable page.
- [ ] Prior history/tool behavior remains intact and visible changes include screenshots.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
