# 02: Restore one-tap v2 message revert

**What to build:** A user can revert a selected message in a v2 session with one action. Any stale staged revert is cleared using the v2 operation before staging and committing the new boundary, and the UI refreshes from the canonical session afterwards.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The revert sequence uses operations and methods accepted by the v2.0.16 contract, including its delete-based clear operation, rather than an unrecognized clear route.
- [ ] Reverting an eligible message updates the visible session, transcript, and diffs without a route-not-found error.
- [ ] Busy-session or partial-operation failures remain recoverable and report the refreshed state; v1 one-tap revert is unchanged.
- [ ] A contract-shaped test rejects an unrecognized route or wrong method instead of accepting a fabricated success response.
