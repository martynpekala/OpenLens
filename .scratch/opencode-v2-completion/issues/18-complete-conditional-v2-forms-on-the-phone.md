# 18: Complete conditional V2 forms on the phone

**What to build:** Finish forms using supported conditional field rules through the existing native form interaction.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] Supported when predicates determine active fields and update when dependent answers change.
- [ ] Only active fields are validated and included in the submitted reply.
- [ ] Hidden required fields do not block submission or leave stale answers in the payload.
- [ ] Existing string, numeric, Boolean, multiselect, and external flows retain their validation behavior.
- [ ] Unsupported predicates/types remain explicit and do not cause guessed or unsafe submissions.
- [ ] Branch changes, defaults, boundaries, recovery, and reply ownership are covered through services and Remote.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
