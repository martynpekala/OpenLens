# 14: Attach text files and repository line references

**What to build:** Provide supported text from Files or focused repository context through the existing attachment composer.

**Blocked by:** 13: Send screenshots and supported photos in V2 prompts.

**Status:** done

**Priority:** P2

- [x] A supported UTF-8 file from Files can be previewed, removed, and submitted with its text prompt.
- [x] A repository picker can add a server file reference and an optional supported start/end line range.
- [x] Phone data and server file URIs remain distinct; phone paths and HTTP URLs are not treated as usable server files.
- [x] Incoming file attachments remain intelligible after admission and history reload.
- [x] Combined attachments and prompt size respect the actual direct/Remote limits and exact retry identity.
- [x] Location approval and line-range errors are exercised through the client and gateway.
  - Gateway attachment, line-range, and duplicate-key checks are covered by pure tests that pass; the gateway integration test (incl. `/command`) is blocked locally by the pre-existing EPERM (Code=513) WorkspaceRegistry write failure that also affects 13 baseline tests.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
