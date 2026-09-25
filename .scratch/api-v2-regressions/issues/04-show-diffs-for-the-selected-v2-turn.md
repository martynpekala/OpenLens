# 04: Show diffs for the selected v2 turn

**What to build:** When a user inspects changes from a particular chat turn on v2, the review shows that turn's files and patches, not the newest turn's default diff.

**Blocked by:** None (can start immediately).

**Status:** contract verified — live-server exercise pending

- [ ] The chosen user message is sent as the v2 turn boundary accepted by the session-diff endpoint; an omitted selection still requests the default diff.
- [ ] Selecting two different turns with different changes produces the matching review content for each.
- [ ] A contract-shaped request test prevents use of an unsupported message-boundary parameter; v1 turn diffs keep their existing behavior.

## Audit evidence — 2026-09-25

The from parameter was correct, but the client required a location envelope absent from the actual response. Fixed to decode {data}; tests now return that shape and exercise different selected turns with another active directory. See [audit](../AUDIT.md) for test results and remaining release blockers.
