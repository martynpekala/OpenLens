# 04: Cancel pending V2 prompts and promote queue to steer

**What to build:** Control an eligible pending prompt directly from the shared queue by canceling it or changing its delivery mode.

**Blocked by:** 03: Restore the shared V2 session inbox after reconnecting.

**Status:** done

**Priority:** P1

- [x] An eligible pending user entry offers cancellation and the supported queue-to-steer transition.
- [x] Successful changes are reconciled with the server inbox rather than applied permanently through local assumptions.
- [x] Delivery races, already consumed entries, and failed mutations leave the queue accurate and retryable.
- [x] Interrupting active execution does not imply that remaining pending work has been deleted.
- [x] The UI does not offer accepted-text editing, arbitrary reordering, or unsupported control-entry mutations.
- [x] Behavior tests exercise cancellation and promotion through the production client and direct-session routing policy. Remote ownership policy is no longer applicable after Remote was removed in `77b72ac`.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services. Remote isolation is no longer applicable after `77b72ac`.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.

**Verification:**

- `V2SessionInboxTests` exercises cancellation and promotion through `ChatClient`, `MessagesService` and the production `OpenCodeClient` with an injected transport. Requests keep the existing inbox identity, omit caller location, accept 204 responses and reconcile the inbox and transcript.
- Coverage includes lost responses confirmed by recovery, rejected mutations and retry, entries consumed before mutation, acknowledgments with unchanged server state, failed recovery and retry, duplicate taps, delayed responses after a session switch, unsupported entry kinds, pending admission and interruption preserving queued work. `OpenCodeV2SessionMutationTests` verifies legacy connections send no inbox mutations.
- Ran `xcodegen generate`, then the repository-required `build-for-testing` and `test-without-building -parallel-testing-enabled NO` commands on the designated iPhone 18 Pro simulator. All 519 tests in 55 suites passed on 2026-10-07.
- Full verification exposed fixed-wait races in three existing streaming tests. Their original assertions are retained, with bounded waits for the expected observable state. The 89-test streaming suite also passed independently.
- Separate standards and spec reviews found no remaining actionable findings.
- Verified both actions in the simulator against a local V2 fixture, including individual accessibility focus for each eligible prompt's menu. Screenshots show the [pending prompt actions](../screenshots/04-pending-prompt-actions.png) and [the reconciled queue after promotion](../screenshots/04-promoted-prompt.png).
- DELETE/PATCH contracts were checked against pinned upstream release 2.0.23. Remote gateway verification is not applicable after `77b72ac`; a live two-client V2 server run was not performed.
