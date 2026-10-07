# 03: Restore the shared V2 session inbox after reconnecting

**What to build:** Show the authoritative pending session inbox, retaining accepted prompts from every client after reopening, reconnecting, or a stream gap.

**Blocked by:** 02: Confirm V2 prompt admission and retry without duplicate work.

**Status:** done

**Priority:** P1

- [x] The queue is projected from server inbox identities and distinguishes pending admission from already accepted work.
- [x] User, synthetic, compaction, and move entries retain their supported type, order, delivery mode, and relevant presentation.
- [x] Opening the session, foregrounding, reconnecting, and inbox delivery/cancellation events reconcile the same queue.
- [x] A session is not reported synchronized if required inbox recovery fails; a successful retry completes recovery.
- [x] Switching sessions or connections prevents delayed inbox results from changing the new session.
- [x] An externally admitted pending prompt survives an app-state reset without duplication or client-side promotion of another queued entry.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services. Remote isolation is no longer applicable after Remote was removed in `77b72ac`.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.

**Verification:**

- `V2SessionInboxTests` covers all four supported entry types, pending versus accepted admission, inbox events, recovery and retry, delayed responses after session changes or resets, and restoring external work without duplication or local promotion.
- Regression coverage verifies failed post-admission recovery clears synchronization, distinct IDs with matching command text remain visible, and steered compaction takes priority without crossing a steered move. Queued compaction retains its queue position.
- Ran `xcodegen generate`, then the repository-required `build-for-testing` and `test-without-building -parallel-testing-enabled NO` commands on the designated iPhone 18 Pro simulator. All 507 tests passed on 2026-10-07.
- [Simulator screenshot of the shared queue](../screenshots/03-shared-v2-session-inbox.png), captured against a local V2 transport fixture, shows compaction before the earlier steer and two distinct entries with identical text.
- Remote gateway verification is not applicable to this checkout after `77b72ac`. A live two-client V2 server run was not performed.
