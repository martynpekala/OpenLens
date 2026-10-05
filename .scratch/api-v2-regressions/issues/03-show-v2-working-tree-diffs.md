# 03: Show v2 working-tree diffs

**What to build:** In a v2 project, opening a changed file shows its working-tree patch rather than silently falling back because the diff request was rejected.

**Blocked by:** None (can start immediately).

**Status:** contract verified — live-server exercise pending

- [ ] The working-tree diff request uses the v2.0.16 working mode and succeeds without HTTP 400.
- [ ] Changed-file detail displays the returned patch; its content fallback still handles files without a patch.
- [ ] A request-contract test checks the accepted mode, and existing v1 review behavior remains unchanged.

## Audit evidence — 2026-09-25

The working mode was correct; this audit removed the undocumented format parameter. Workspace request and ReviewFileChange patch mapping tests pass. See [audit](../AUDIT.md) for test results and remaining release blockers.
