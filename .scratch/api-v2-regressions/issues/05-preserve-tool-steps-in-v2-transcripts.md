# 05: Preserve tool steps in v2 transcripts

**What to build:** Reloading or reopening a v2 chat restores the assistant's tool steps alongside its text, so the timeline does not lose tool activity after streaming ends.

**Blocked by:** None (can start immediately).

**Status:** transcript contract verified

- [ ] A persisted v2 assistant message with a contract-shaped named tool and its state produces a visible tool step after transcript loading.
- [ ] Running, completed, and failed tool states retain useful labels and details without mistaking unrelated content for a tool.
- [ ] A regression test exercises the decoded v2 transcript through the chat presentation path; v1 tool steps still display.

## Audit evidence — 2026-09-25

Existing named-tool decoding and presentation tests cover running, completed and failed states. This audit additionally preserves assistant execution errors on reload. Native streaming is now implemented and automatically verified in issue 07. See [audit](../AUDIT.md) for test results and remaining release blockers.
