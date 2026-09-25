# API v2 regression audit — 2026-09-25

Verdict: **all three identified implementation blockers fixed and automatically verified**. The original contract corrections and the follow-up fixes pass the full app and relay suites. Live v2 release certification remains pending because no live v2 direct/paired server was available.

## Original regression issues

| Issue | Audit result |
| --- | --- |
| 01 — Session project context | Location decode and project switching are covered; native event adaptation and cross-location filtering now pass automated coverage; live acceptance remains pending. Fixed the session-list directory filter. |
| 02 — One-tap revert | Direct sequence was correct. Fixed relay rejection of DELETE /revert and removed its obsolete clear route. Recovery tests pass; live v2 exercise remains pending. |
| 03 — Working-tree diff | Working mode and patch presentation were correct. Removed undocumented format query. Automated coverage passes. |
| 04 — Selected-turn diff | `from` was correct, but response decoding wrongly required location. Fixed to use `{data}` and no location query; different selected-turn fixtures pass. |
| 05 — Persisted tool steps | Named tools and running/completed/error state mapping pass transcript/presentation tests. Additionally fixed lost assistant execution errors. |
| 06 — Model capabilities/prices | Capabilities were correct; actual context-tier objects broke catalog decoding. Fixed tier decoding and replaced integer-tier mocks with documented objects. |

Original issue checkboxes are not blanket-checked: they include live-server/UI acceptance that was not executed.

## Additional fixes made

- Create sessions with location in the JSON body, not a query the endpoint does not accept.
- Filter session pages with `directory`, retaining it across cursor pages.
- Reply to v2 permissions with `decision`; preserve v1 `reply`.
- Persist the negotiated protocol for widget actions, and test the actual shared widget request builder for both protocols and both decisions.
- Encode command attachments as objects (`uri`, `name`, `id`), not string arrays.
- Retain `{type,message,status?}` assistant errors through transcript projection.
- Validate the relay's session-create body location against its registry, reject conflicting/unregistered/encoded selectors, and inject a canonical location when omitted.
- Use endpoint-specific relay location queries. This is request-contract correctness, **not** proof of session/event authorization.

## Resolved release blockers

### P1 — Native v2 stream support

Added `V2EventAdapter` ahead of legacy decoding. Native envelopes now map text, reasoning, assistant steps, tools, permissions, and forms into the existing chat pipeline. Assistant step completion preserves distinct messages across multi-step generations. Execution and other canonical state changes trigger REST reconciliation. Unknown events remain tolerated. Selected-directory filtering rejects foreign frames; `/api/event` no longer receives an undocumented directory query.

Contract-shaped transport tests exercise visible chat output, multi-step completion, terminal tools, pending interactions, unknown events, and foreign-location exclusion. Legacy stream coverage remains passing. See [issue 07](issues/07-consume-native-v2-events.md).

### P1 — Remote ownership enforcement

Session-owned operations now perform a fresh canonical session lookup and validate its location against the registry before forwarding. Active snapshots and session/project lists are filtered. A bounded incremental SSE filter emits only approved native location events plus sanitized connection/heartbeat events. Ownership and registry changes are rechecked without an ownership cache.

Integration tests cover foreign reads and mutations, permitted operations, moved sessions, revoked registry entries, active snapshots, byte-fragmented frames, and oversized incomplete frames. See [issue 08](issues/08-enforce-remote-session-and-event-ownership.md).

### P2 — Complete reconciliation

Status and pending-interaction recovery now return explicit success/failure. Synchronization requires successful canonical session, transcript, status, and interaction recovery, with cancellation/session checks preventing stale application. HTTP stream reconnection requires a new reconciliation. Gap generations prevent a recovery pass from acknowledging a newer gap that occurred while it was running.

Tests reproduce status, permission, and form recovery failures, verify successful retries, reject stale session results, and check reconnect/decode-gap acknowledgement. See [issue 09](issues/09-require-complete-v2-reconciliation.md).

## Verification and test cleanup

- Required original destination UUID was absent. The user explicitly approved booted iPhone 18 Pro `49C08F47-0325-4C9E-A7FE-7AD7016CBEBD` (iOS 27).
- Ran `xcodegen generate` and full `xcodebuild ... test`: **323 tests in 39 suites passed**, including app/widget build.
- Generated the Mac project with `tuist generate --no-open`; full `OpenLensRemote` macOS suite: **19 tests passed**.
- The strengthened contract checks first failed on the original behavior (12 issues). Tier/error checks separately failed (3 issues), then passed after fixes.
- Removed `hidesTabBarWhenReturningFromSettingsIntoChatSession`: its body was identical to `hidesTabBarWhenChatSessionIsPresented` and exercised no transition.
- Scanned test method bodies for other exact duplicates; none remained. Kept pagination, v1 compatibility, safety, protocol, stream/backpressure, and recovery tests because they protect distinct behavior. Corrected misleading fixtures instead of deleting useful tests.
- No live v2.0.16 direct/paired server was available; locally installed `opencode` reports 1.15.5. No live generation, provider billing, end-to-end widget action, or screenshot-based UI acceptance was performed. No UI layout was changed.
- All three follow-up blockers were reproduced with failing tests before fixes. Passing suites cover the asserted contract and recovery cases; they do not substitute for live direct/paired v2 smoke testing.

## Contract evidence

Downloaded official [OpenAPI](https://opencode.ai/v2/openapi.json) on 2026-09-25. SHA-256: `8ab6ec800922fc68890c68134320b4063fb317e0d944252d232083e12d32f4e9`. This is a current schema snapshot, not a claim that a live v2.0.16 server was exercised.

Native stream review used official [event group](https://github.com/anomalyco/opencode/blob/v2/packages/protocol/src/groups/event.ts), [event envelope](https://github.com/anomalyco/opencode/blob/v2/packages/schema/src/event.ts), [session events](https://github.com/anomalyco/opencode/blob/v2/packages/schema/src/session-event.ts), and [event manifest](https://github.com/anomalyco/opencode/blob/v2/packages/schema/src/event-manifest.ts).

Fetched event-group SHA-256: `de5857bb0a9baf94e165f95978c0ae1affe70abce5182ffb01225afae507fbd0`; session-events SHA-256: `1c747fc453dea55c838baf79a572cb675ca8cc60a5a9608160781a343cb898d6`.

Test logs for this run: `/tmp/openlens-blockers-final3.log` and `/tmp/openlens-relay-blockers-final.log` (temporary local artifacts).
