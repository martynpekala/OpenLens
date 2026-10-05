# 02: Confirm V2 prompt admission and retry without duplicate work

**What to build:** Distinguish sending, accepted, uncertain, and failed prompts and safely retry an identical submission after an ambiguous network failure.

**Blocked by:** None (can start immediately).

**Status:** done

**Priority:** P1

- [x] Normal, queued, and steering prompts use the released flat V2 admission contract and retain the returned admission identity.
- [x] Each submission has a stable caller ID; an exact retry reuses both that ID and the same content.
- [x] A timeout after possible admission becomes an uncertain state that is reconciled with authoritative inbox/history before creating new work.
- [x] Changing prompt content creates a new admission ID rather than attempting to edit an accepted entry.
- [x] The composer preserves recoverable input and does not display a network timeout as proof of server rejection.
- [x] A controlled server accepts once, loses the response, and receives a retry without a second task or duplicate visible prompt.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
