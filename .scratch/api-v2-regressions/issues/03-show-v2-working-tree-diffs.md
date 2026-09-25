# 03: Show v2 working-tree diffs

**What to build:** In a v2 project, opening a changed file shows its working-tree patch rather than silently falling back because the diff request was rejected.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] The working-tree diff request uses the v2.0.16 working mode and succeeds without HTTP 400.
- [ ] Changed-file detail displays the returned patch; its content fallback still handles files without a patch.
- [ ] A request-contract test checks the accepted mode, and existing v1 review behavior remains unchanged.
