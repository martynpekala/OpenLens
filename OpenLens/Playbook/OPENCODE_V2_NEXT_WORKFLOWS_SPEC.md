# Complete the remaining OpenCode V2 mobile workflows

Originally drafted 2026-10-19 at `2d5a6b0`. **Re-evaluated 2026-10-21** at `aa9932f`, whose app and test sources are identical to `2d5a6b0`: none of the workflows below is implemented yet. This revision keeps only the workflows judged worth building; the prioritized breakdown with per-ticket justification lives in [the ticket draft](OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md).

## Problem Statement

OpenLens already shares a durable session inbox with other OpenCode clients, lets people cancel or steer pending prompts, attach images and files, use skills, inspect context, request compaction, answer forms, and see execution outcomes and unread results. These remain the foundation and are not reimplemented.

The remaining gaps still send people back to their computer or let them make risky decisions blind:

- A subagent result is visible, but its conversation cannot be opened.
- A conversation cannot be branched; the only way to try another approach is an undo that immediately rewrites files.
- Attaching a deeply nested file requires browsing every folder, and a failed skill catalog looks like an empty one.
- A permission can be rejected but not explained, and permissions granted with Always cannot be inspected or revoked.
- Review only compares the working copy, so work the agent already committed disappears from review.
- Returning to a long task offers no quick catch-up without scrolling the full history.
- The main session list and every conversation fetch their complete history before display, and the activity calendar reads every matching transcript.
- A parallel task cannot be started in an isolated worktree.

## Solution

Extend existing screens and services in four ordered stages:

1. **Small, high-value changes:** permission rejection message, child-session navigation, file search in the attachment picker with a skill-catalog error state, and transient session summaries.
2. **Control over agent work:** fork (full history, then before a selected message), an explicit undo confirmation with history-only vs. history-and-files scope, saved-permission inspection and revocation, and branch/committed review with an explicit base.
3. **Scaling:** paged main session list with server search, newest-first transcript paging, and server-side statistics for Insights and the activity calendar with the current computation as fallback.
4. **Isolated tasks:** create a worktree and start a new session in it.

Unsupported operations have an explicit unavailable state. Delayed responses must not overwrite a different session, project, or comparison. A failed request must not discard a draft, imply success, or duplicate side effects through an unsafe retry. The current direct HTTP/SSE connection model, including an OpenCode tunnel address, is the only transport; the removed OpenLens Remote gateway is not part of this work.

## User Stories

Grouped by ticket number (`next-workflows/NN`).

**12 — Permission rejection message**
1. As a user, I want to optionally explain why I reject a permission request, so that the agent can adjust its next action without a separate prompt.
2. As a user, I want a failed rejection to keep my explanation, so that I can retry without retyping it.

**01 — Child sessions**
3. As a user, I want to open a child conversation from its delegated-work card, so that I can inspect the actual work behind its summary.
4. As a user, I want to return to the parent without losing my place or draft.
5. As a user, I want a missing or unavailable child to have an explanation, so that I do not mistake a failed navigation for an empty task.
6. As a user, I want permissions and forms to keep their owning session while I navigate between parent and child.

**04 / 05 — Attachment search and skill catalog**
7. As a user, I want to search repository files from the attachment picker in the session's verified location, so that I can attach context without browsing every folder.
8. As a user, I want to attach a found file or line range through the existing preview and validation flow.
9. As a user, I want no results, failure, and unsupported search to be distinct, and stale results ignored after I change the query.
10. As a user, I want a failed skill-catalog request to be distinct from an empty catalog, with a retry that keeps my draft.

**14 — Transient summary**
11. As a user returning to a task, I want an on-demand summary or next-step explanation that does not add a message to the conversation.
12. As a user, I want the explanation marked as model output, separate from compaction and execution status, and regenerated only when I ask.
13. As a user, I want a generation failure to leave the conversation unchanged.

**02 / 03 — Fork**
14. As a user, I want to fork the full conversation or the history before a selected message, so that I can try another approach without losing the original.
15. As a user, I want the fork action to state whether the selected message is included.
16. As a user, I want the fork to appear in navigation and the session catalog, distinguishable from a subagent child, with settings and location taken from the returned server state.
17. As a user, I want to know that a fork shares the same files, and I want an uncertain fork response not to create a second fork automatically.

**13 — Undo confirmation**
18. As a user, I want to see the message boundary affected by undo and choose between reverting history only or history and files.
19. As a user, I want to be told that the file variant changes disk immediately, so that I do not mistake it for a preview.
20. As a user, I want a busy session or failed undo reconciliation to remain explicit, so that the app does not claim a rollback that did not complete.

**10 — Saved permissions**
21. As a user, I want to inspect saved permission rules for the intended project and revoke one.
22. As a user, I want to know that revoking a rule does not undo completed actions.

**09 — Branch review**
23. As a user, I want separate working, branch, and committed comparisons with a selectable base.
24. As a user, I want a changed base or project to invalidate an older diff, and an unavailable or ambiguous comparison to have a clear state instead of an empty diff.

**06 / 07 — Session list paging and search**
25. As a user with many sessions, I want recent rows to appear before the whole catalog is fetched, and to load older sessions without losing my selection or creating duplicates.
26. As a user, I want a later-page error to keep loaded sessions and offer retry.
27. As a user, I want server-side session search that states what it searches, so that I do not assume it searches message bodies.

**08 — Transcript paging**
28. As a user opening a long conversation, I want the newest page first and older pages on demand without losing my reading position.
29. As a user, I want messages, context entries, tool files, and subagent results to stay ordered across page boundaries and live updates.
30. As a user, I want incomplete history to be labeled wherever it affects totals, undo, or review.

**16 — Server statistics**
31. As a user, I want activity, model usage, and costs filtered by project, time range, and my time zone, described as server-recorded usage rather than provider billing.
32. As a user on a server without statistics, I want the current Insights and calendar to keep working with a correct scope label.

**20 — Worktree task**
33. As a user, I want to create a worktree and start a new session in it, so that a parallel task cannot edit the same files.
34. As a user, I want setup progress and failure to be visible, and a worktree created before a session failure to remain recoverable without a duplicate directory.

**All workflows**
35. As a user on an older server, I want unsupported additions to be clearly unavailable while existing chat keeps working.
36. As a user on an unreliable connection, I want reconnect recovery to reconcile authoritative state before claiming synchronization.
37. As a user switching sessions during a request, I want late results to stay with the session that initiated them.

## Implementation Decisions

1. **Current branch is the baseline.** Preserve queue recovery and mutations, admission IDs, attachment preparation, skills, context projection, compaction, forms, outcome/viewed, and location recovery.
2. **Keep the existing architecture.** Extend ChatClient and the existing session, workspace, review, interaction, and insights services. Shared observable services through the environment; screen-local loading/loaded/error state stays local. No ViewModel, VM, Presenter, or parallel networking stack.
3. **Use existing transport boundaries.** OpenCodeClient remains the protocol adapter. Keep V1 behavior. Do not treat a successful V2 info probe as proof that every endpoint exists; distinguish missing resource, unsupported operation, and connection error. Never mutate the server to probe capabilities.
4. **Keep navigation native.** Extend existing session destinations and preserve draft/return context for parent, child, and fork. Tab-bar hiding stays on the connected root navigation stack.
5. **Rejection message.** Send the optional text only through the supported `message` field of `session.permission.reply`; omit it for V1.
6. **Child ownership vs. fork lineage.** Validate linked identifiers and load canonical session state before display. The fork contract describes its result as a child session, while `SessionsService` hides sessions with a `parentID`; root filtering must not hide forks or present them as subagents.
7. **Fork contract.** Use `session.fork` with an exclusive `before` boundary, or omit it for full history. Settings and location come from the created session. No filesystem isolation is implied. Never retry an ambiguous fork automatically.
8. **Attachment search.** Use `fs.find` in the session's verified location and reuse file selection, line-range validation, preview, attachment preparation, admission, and the complete-payload size check. No full-text code search. Folder browsing remains.
9. **Catalog failures.** The skill-catalog service distinguishes empty success, failure, and unavailability; retry refreshes the current location without touching the prompt.
10. **Transient summaries.** Use `session.generate` with a fixed summary/next-step prompt. Display outside the transcript, cache against session identity and transcript revision, require an explicit regenerate. It is a model call with cost, not status and not compaction.
11. **Undo confirmation.** Before calling revert, show the boundary and let the user choose `files: false` or `files: true` for `revert/stage`, then commit as today. Explain that the file variant changes disk. Reconcile session/diff from canonical state after errors or lost responses. A user-visible staged state with clear/restore is out of scope until restoration semantics are confirmed upstream.
12. **Saved rules.** Use `permission.saved.list` and `permission.saved.remove` with the project scope; refresh canonical rules after mutation. Removal affects future authorization only.
13. **Review modes.** Add `vcs.diff` working, branch, and committed modes with explicit `base` (from `vcs.base` / `vcs.branch.list`). Working compares HEAD to the working copy; branch compares the base merge-base to the working copy; committed compares that merge-base to HEAD. Session/turn review stays separate. Mode/base/location changes invalidate older responses.
14. **Page primary screens.** Reuse existing page helpers and Review's pagination behavior: opaque cursors, filters, stable identities, retained content on retry, protection against repeated/invalid cursors. Add `session.list` search only after confirming its semantics, and state the scope in the UI.
15. **Newest transcript first.** Fetch the latest page (`order=desc`), normalize order, prepend older pages on demand, and merge pages with SSE by stable identity across messages and context entries. Preserve the reading anchor; unread acknowledgement stays tied to a displayed completion.
16. **Analytics coverage.** Paging must not silently degrade Insights, undo, or turn review: keep a separate complete read or label partial coverage. Never compute totals from whatever the UI has loaded.
17. **Statistics.** Use `experimental.session.stats` (`from`, `to`, `project`, `timezone`, `tools=none`) for Insights and the activity calendar. Preserve missing values, avoid double-counting parent/child, label as local server accounting. Keep the current computation as fallback.
18. **Worktrees.** Use `worktree.list/create/refresh` with validated project and path inputs. Creation may run setup scripts; show preparation and partial-success states, then create the session in the returned verified directory. Never force-remove a worktree automatically.
19. **Connectivity.** Cover authenticated HTTP/SSE request construction and recovery with injected transport fixtures for the paired address, including a tunnel address. Credentials stay out of diagnostics and user-visible errors.

## Testing Decisions

1. **Primary boundary:** public ChatClient actions and existing service interfaces, with an injected `OpenCodeTransport` simulating the server while keeping the production HTTP client, decoders, transcript projection, and SSE adapters. Assert user-observable state and externally meaningful requests.
2. **Reuse seams and prior art:** V2SessionInboxTests and V2PromptAdmissionTests (stateful mutation), V2SessionLocationTests (stale responses), V2SessionViewedTests (visibility), V2ContextTimelineTests and V2SubagentResultTests (ordered projections), OpenCodePaginationTests and ReviewServiceTests (paging, diffs). New tests use Swift Testing; no production abstraction added only for tests.
3. **Test behavior, not shape:** selected session, visible result, preserved draft, correct comparison, prevented mutation — not private calls or view decomposition.
4. **Per-workflow coverage:** rejection with/without message and V1 omission; valid/missing child and owning-session interactions; first/middle/full fork and ambiguous creation without a duplicate POST; stale query/location for search and skills; undo request body per scope and reconciliation after lost responses; saved-rule scope and failed removal; distinct diff inputs and stale base; opaque/repeated cursors, late-page failure, pages with no visible roots, selected session outside the first page; SSE merge during older-page loading; stats time-zone boundaries, missing metrics, and fallback; worktree success followed by setup/session failure.
5. **No UI or live-server verification** (user decision): no manual inspection, UI automation, screenshot acceptance, or tests against a running server or tunnel. Competing clients, reconnects, and events are modeled with stateful fixtures.
6. **Runner:** `./scripts/test-ios.sh` on the configured iPhone 18 Pro simulator; focused runs while iterating, full suite at the end. Report genuine failures with preserved logs.

## Out of Scope

- Reimplementing completed inbox, admission, attachments, skills, outcomes/viewed, timeline, context/compaction, forms, or externally initiated move recovery.
- Editing saved permission rules (revoke and re-grant covers the need).
- A staged-undo lifecycle with clear/restore; initiating session moves from the phone; fork-into-worktree composition.
- Session export and import; tool-reliability statistics.
- A recursive task-tree explorer; full-text repository or message search.
- Native git stage/commit/push/merge/checkout, PR creation, or patch application.
- Destructive worktree cleanup, copying uncommitted changes, or treating fork as filesystem isolation.
- Provider/MCP administration and login, plugin updates, credential browsing, plugin RPC.
- Interactive PTY, read-only terminal, realtime voice, source-code editing.
- APNs/backend push, scheduled execution, enforced cost budgets.
- Reintroducing the removed OpenLens Remote gateway or bundled helpers.
- UI checks, screenshot acceptance, and live-server testing.

## Further Notes

The upstream basis is the official OpenAPI snapshot of 2026-10-19 (144 operations, SHA-256 `27de5afb635ac3f3be48f930d50716e11a6c46a5ac36fc24ad8eea1e6e3281a9`), not re-fetched. All operations above are outside `/api/experimental/` except `session.stats`, which therefore keeps a fallback. The `search` parameter of `session.list` has no documented semantics and must be confirmed before ticket 07. Source: [OpenCode V2 OpenAPI](https://dev.opencode.ai/v2/openapi.json).

Older backlog tickets map to this scope as follows: 23 → 01; 21 → 02/03; 35 → 04; 05 (current gap only) → 05; 31 → 06/07; 32 → 08; 29 → 09; 25 (inspect/revoke, rejection message) → 10/12; 26 (confirmation only) → 13; 33 (usage and calendar) → 16; 20 → 20. Obsolete gateway criteria in older tickets are not implemented. This specification does not mark any ticket done.
