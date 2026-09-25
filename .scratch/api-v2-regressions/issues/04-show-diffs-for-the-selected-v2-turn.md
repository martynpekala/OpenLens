# 04: Show diffs for the selected v2 turn

**What to build:** When a user inspects changes from a particular chat turn on v2, the review shows that turn's files and patches, not the newest turn's default diff.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The chosen user message is sent as the v2 turn boundary accepted by the session-diff endpoint; an omitted selection still requests the default diff.
- [ ] Selecting two different turns with different changes produces the matching review content for each.
- [ ] A contract-shaped request test prevents use of an unsupported message-boundary parameter; v1 turn diffs keep their existing behavior.
