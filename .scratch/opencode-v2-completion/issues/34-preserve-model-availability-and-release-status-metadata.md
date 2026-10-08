# 34: Preserve model availability and release-status metadata

**What to build:** Understand supported model status metadata and keep saved selections recoverable when availability changes.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P3

- [ ] Supported enabled/status and release-status metadata survive catalog decoding and appear where useful.
- [ ] Unavailable selections remain understandable and recoverable rather than silently deleted or used for new work.
- [ ] Integration/catalog changes trigger an appropriate refresh without discarding explicit session settings.
- [ ] The stock 2.0.23 enabled filtering is respected; this ticket does not claim a reproduced disabled-model selection bug.
- [ ] Older catalog shapes remain decodable and both direct/Remote model lists retain the same intended scope.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
