# 01: Open v2 sessions in their own project context

**What to build:** Opening an existing v2 session from another project selects the directory carried by that session's location, so the chat, project header, branch, commands, files, and live-event subscription all refer to the session's project rather than the previously selected one.

**Blocked by:** None (can start immediately).

**Status:** partially verified — live-event acceptance remains open

- [ ] An existing v2 session whose directory is supplied only through its location switches the active project context when opened, including after switching between two projects.
- [ ] A contract-shaped v2 session response retains its directory through decoding and session selection; the v1 session shape still works.
- [ ] Live events continue to use the selected session directory after the switch; verify against v2.0.16 when an accessible server is available.

## Audit evidence — 2026-09-25

Session location decoding and project switching are covered by OpenCodePaginationTests and SessionsServiceTests. Native v2 event handling and cross-location exclusion are now implemented and automatically verified in issue 07; live server acceptance remains pending. The session-list directory filter was corrected during this audit. See [audit](../AUDIT.md) for test results and remaining release blockers.
