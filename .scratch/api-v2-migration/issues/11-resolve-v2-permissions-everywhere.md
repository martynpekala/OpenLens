# 11: Resolve v2 permissions everywhere

**What to build:** Pending permissions can be recovered after gaps and answered from chat, inbox, Micro UI, and the widget using session-scoped v2 replies.

**Blocked by:** 06: Synchronize v2 live chat after stream gaps; 07: Send a normal v2 chat turn.

**Status:** ready-for-agent

- [ ] A pending v2 permission retains its session identity, is refreshed after synchronization gaps, and can be approved once, approved always, or rejected safely.
- [ ] Chat, inbox, Micro UI, and widget entry points perform the same session-scoped v2 decision without retaining a separately assembled legacy route.
