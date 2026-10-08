# Complete OpenCode V2 support in OpenLens

## Problem Statement

OpenLens already supports the core OpenCode V2 chat API, including protocol negotiation, prompts, queue and steer admission, interruption, permissions, forms, model selection, revert, pairing, and recovery after a stream gap. The remaining work is to make those capabilities reliable when the same session is used from an iPhone and another OpenCode client, and to expose the V2 operations that are most useful on a phone.

Today, the iPhone can reconstruct a model selection from an older message and send it back before a prompt, potentially overwriting a newer selection made on the desktop. Its displayed follow-up queue is local rather than a projection of the server inbox. Some execution outcomes, context changes, and subagent results are discarded when building the transcript. Skills requested through Remote are blocked by the gateway route table, and the QR helper still uses a TUI attachment command absent from the current V2 CLI.

Users also cannot complete several useful workflows entirely from the phone: attach a screenshot or document from Files, inspect the agent's active context, finish a conditional form, create work in an isolated Git worktree, or inspect background work and saved approvals. Long session lists and transcripts can require fetching all pages before the useful content appears.

These gaps make it harder to trust that the phone and desktop show the same work, to continue a task after reconnecting, and to understand what the agent is doing without returning to the computer.

## Solution

Complete V2 support in four ordered stages while preserving the existing V1 experience and the native OpenLens architecture.

1. **Stage A: consistent sessions across clients.** Treat server session settings and inbox entries as authoritative. Preserve model variants, execution outcomes, project changes, and V2 subagent results. Restore skills through Remote and update QR helper startup for V2.
2. **Stage B: useful input and context on the phone.** Support screenshots, supported images, text files, repository references, and file results from tools. Expose active context, compaction, relevant timeline events, and conditional forms.
3. **Stage C: parallel work.** Add explicit worktree creation, conversation forks, session moves, child-session navigation, and observation of supported background tools.
4. **Stage D: control and diagnostics.** Manage saved approvals, make staged revert understandable and reversible, show integration and MCP status, and add supported branch review and session export.

Use incremental loading, capability checks, and the same behavior through direct connections and Remote throughout these stages. A stage is complete only when its observable behavior has been verified, including the corresponding Remote routes and recovery paths.

## User Stories

1. As an OpenLens user, I want the current model, reasoning variant, and agent to match the server session, so that I know which settings will handle my next request.
2. As a user switching between desktop and iPhone, I want settings changed on the desktop to appear on the phone before another response exists, so that the phone continues with my latest selection.
3. As a user switching between desktop and iPhone, I want sending an ordinary prompt to preserve the current session settings, so that the phone does not silently restore older settings.
4. As an OpenLens user, I want an explicit model or agent change to be applied before my next prompt, so that my deliberate selection takes effect predictably.
5. As an OpenLens user, I want defaults for a new session to remain separate from the settings of an existing session, so that saved preferences do not change work already in progress.
6. As an OpenLens user, I want to see pending work admitted by every client into the session inbox, so that I can understand everything the agent is expected to do next.
7. As an OpenLens user, I want accepted pending work to reappear after reopening the app or reconnecting, so that I do not lose sight of tasks already stored on the server.
8. As an OpenLens user, I want to distinguish a request still being sent from one accepted by the server, so that I know whether it is safe to retry.
9. As an OpenLens user with an unstable connection, I want a retry of the same prompt to reuse its admission ID, so that a lost response does not create duplicate work.
10. As an OpenLens user, I want to cancel a prompt that has not been delivered, so that the agent does not execute work I no longer need.
11. As an OpenLens user, I want to promote an eligible queued prompt to steering, so that it can guide the current execution at its next supported boundary.
12. As an OpenLens user, I want queue, steering, cancellation, and interruption to have distinct meanings, so that stopping active work does not imply that all pending work was removed.
13. As an OpenLens user, I want to see pending compaction and session-move operations alongside queued work, so that changes affecting later prompts are visible.
14. As an OpenLens user, I want the app to show whether execution succeeded, failed, or was interrupted, so that an idle session is not mistaken for a successful task.
15. As an OpenLens user, I want requests waiting for permission or form input to remain visible, so that I can unblock work from the phone.
16. As an OpenLens user, I want new execution results to be marked unread until I view them, so that I can find tasks that finished while I was away.
17. As a user moving a session from the desktop, I want the phone to update its project, files, commands, and event filtering, so that further actions use the session's current location.
18. As an OpenLens user, I want a failed recovery to remain visibly incomplete and retryable, so that partially refreshed state is not presented as synchronized.
19. As an OpenLens user switching sessions during recovery, I want delayed results from the previous session to be ignored, so that they cannot overwrite the session I am viewing.
20. As an OpenLens Remote user, I want the same skill catalog as a direct connection to the same approved workspace, so that skill mentions work away from the computer.
21. As an OpenLens user, I want a catalog-loading error to be distinguishable from an empty catalog, so that I can diagnose an unavailable feature.
22. As an OpenLens user, I want both legacy task tools and V2 subagent tools to appear as delegated work, so that the experience remains useful across supported protocols.
23. As an OpenLens user, I want a child that is still running to remain marked as running after its launch tool succeeds, so that I do not assume the task has finished.
24. As an OpenLens user, I want background subagent completion, failure, and cancellation results to appear in the parent history, so that I can see the outcome even before another model response.
25. As a user of the QR helper, I want the opened TUI and paired phone to target the same server, so that both clients show the same sessions and work.
26. As a user of the QR helper, I want supported V1 and V2 installations to start using their respective CLI contracts, so that pairing does not depend on an obsolete command.
27. As an OpenLens user, I want to attach a screenshot or supported photo to a prompt, so that I can show the agent a UI or error directly from the phone.
28. As an OpenLens user, I want to attach a supported UTF-8 file from Files, so that I can provide text without manually pasting it.
29. As an OpenLens user, I want to reference a server repository file and optionally a range of lines, so that I can give the agent focused source context.
30. As an OpenLens user, I want attachments created on the desktop to appear in the phone transcript, so that the same conversation remains understandable on both clients.
31. As an OpenLens Remote user, I want size validation and image preparation to account for the complete encoded request, so that an attachment does not fail unexpectedly at the gateway.
32. As an OpenLens user, I want an explanation when the server or selected model cannot accept an attachment, so that I can choose another supported input.
33. As an OpenLens user, I want supported files and images returned by tools to be visible, including useful partial results on failure, so that tool output is not reduced to text alone.
34. As an OpenLens user, I want relevant model, agent, location, skill, shell, compaction, and completion entries to remain visible in the timeline, so that I can understand changes in the agent's behavior.
35. As an OpenLens user, I want to inspect the active context separately from the full conversation history, so that I know what the agent currently sees.
36. As an OpenLens user, I want to request compaction and inspect its status and summary, so that I can continue a long conversation with an understandable reduction of context.
37. As an OpenLens user, I want any context-usage indication to reflect current context data rather than cumulative historical token usage, so that it does not overstate how full the model's context window is.
38. As an OpenLens user, I want conditional form fields to appear or disappear as my answers change, so that I can complete supported interactions from the phone.
39. As an OpenLens user, I want validation and submitted answers to include only active form fields, so that hidden requirements do not block or corrupt my response.
40. As an OpenLens user, I want supported global MCP forms to be reachable outside the current chat, so that I can complete interactions that do not belong to a normal session.
41. As an OpenLens user, I want unsupported form semantics to remain explicit, so that the app does not guess an answer on my behalf.
42. As an OpenLens user, I want to create a task in a separate worktree, so that parallel work can use a separate Git working directory.
43. As an OpenLens user, I want to browse existing worktrees with their actual locations, so that I can choose where to continue work.
44. As an OpenLens user, I want to fork a conversation at a supported history boundary, so that I can explore another approach without removing the original conversation.
45. As an OpenLens user, I want the app to explain whether a fork shares the original working directory, so that I do not confuse conversation branching with file isolation.
46. As an OpenLens user, I want to move a session to an available location with visible pending and completed states, so that I know when later work will use that directory.
47. As an OpenLens Remote user, I want a new worktree or move destination to follow the existing Mac workspace-approval policy, so that the phone does not gain access to unapproved directories.
48. As an OpenLens user, I want to open a child session and see its result and pending interactions, so that I can inspect or unblock delegated work.
49. As an OpenLens user, I want to continue a supported foreground tool in the background and inspect its bounded output, so that long-running work does not require a full interactive terminal on the phone.
50. As an OpenLens user, I want unsupported background transitions to be explained, so that the app does not imply that every running process can be detached.
51. As an OpenLens user, I want to inspect and remove saved permission rules within my authorized scope, so that I can reverse a previous always-allow decision.
52. As an OpenLens user, I want to include a reason when rejecting a permission request, so that the agent can understand how to proceed differently.
53. As an OpenLens user, I want to distinguish reverting history from reverting files, so that I understand the effect on the working directory.
54. As an OpenLens user, I want to clear a staged revert before it is committed, so that I can undo the rollback itself when supported.
55. As an OpenLens user, I want the Review flow to explain that staging with files enabled can already change files, so that I do not mistake it for a read-only preview.
56. As an OpenLens user, I want read-only status for integrations and MCP servers, so that I can understand why a model or tool is unavailable.
57. As an OpenLens user, I want to complete a supported authentication attempt from the phone, so that a server-side integration can become available without losing the current session.
58. As an OpenLens user, I want to inspect supported branch or committed diffs in Review, so that I can assess changes beyond a single turn or the current working tree.
59. As an OpenLens user, I want to export a session when the server supports it, so that I can archive it or attach it to a bug report without assuming a public sharing link exists.
60. As an OpenLens user opening a long conversation, I want the latest available messages to appear first and older pages to load on demand, so that I can continue quickly.
61. As an OpenLens user browsing sessions, I want server-supported paging, filters, and search to avoid fetching the whole catalog, so that a large workspace stays responsive.
62. As an OpenLens user viewing Insights or the activity calendar, I want totals to identify their actual data coverage, so that incremental chat loading does not silently turn complete statistics into partial statistics.
63. As an OpenLens user connecting to an older server, I want unsupported optional operations to be unavailable with an explanation, so that a protocol label alone does not promise functionality the server lacks.
64. As an OpenLens V1 user, I want the existing chat, queue, permissions, review, and connection flows to keep working, so that V2 improvements do not force an immediate server upgrade.

## Implementation Decisions

1. **Build on the existing architecture.** Extend OpenCodeClient, ChatClient, the existing session/message/workspace/provider/interaction services, typed server models, Review, and Remote components. Business logic stays in observable services, shared services enter views through the environment, and local presentation state stays in view state. Do not add ViewModel, VM, or Presenter types or a parallel networking stack.
2. **Keep protocol selection separate from feature availability.** Preserve capability negotiation through V2 server info and the existing V1 fallback rules. Authentication and authorization errors must not trigger protocol downgrade. Determine optional operations from reliable capability evidence or non-mutating checks; retain the server version as diagnostic evidence rather than the sole compatibility threshold.
3. **Separate session settings from new-session preferences.** Decode the canonical session agent and model reference, including its variant. Update the current selection on initial load, relevant events, foreground refresh, and recovery. Historical message settings explain earlier work but must not overwrite current session settings.
4. **Change settings only on explicit user intent.** Ordinary prompt admission must not automatically reapply a model or agent inferred from history. A deliberate local switch must finish successfully before admitting a dependent prompt. Serialize those dependent operations per session and retain session identity across awaits; actor isolation alone does not make a multi-request sequence atomic.
5. **Use the server inbox as the accepted queue.** Add typed prompt-admission results and inbox reads, cancellation, and delivery-mode changes. The V2 contracts are `GET /api/session/:id/inbox`, `DELETE /api/session/:id/inbox/:inboxID`, and `PATCH /api/session/:id/inbox/:inboxID` with `delivery`. Include user, synthetic, compaction, and move entries where relevant to the pending-work presentation.
6. **Model uncertain admission explicitly.** Retain a stable caller ID for retries of the exact same prompt. Reconcile an uncertain result with server state before presenting it as failed or sending a different admission. In the researched release, the first admission wins for the same session, type, and ID; changed prompt content requires a new ID and cannot be implemented by reusing the old one.
7. **Preserve the distinct control operations.** Queue waits for a subsequent turn; steer contributes at a supported boundary of current work. Cancel targets a pending inbox entry; interrupt targets active execution. Do not offer arbitrary inbox reordering or editing its accepted text because the public contract does not provide those operations.
8. **Extend recovery as one coordinated operation.** Refresh canonical session settings and location, transcript, inbox, execution status, and pending permissions/forms before marking synchronization complete. Coalesce repeated refreshes, cancel obsolete work, and reject stale results after a session or connection change. Global SSE is volatile; a reconnect or event ID must not be treated as proof of replay.
9. **Preserve outcomes and read markers.** Decode idle/viewed times and outcomes, and project relevant idle timeline entries. Separate succeeded, failed, and interrupted results from active execution and pending user interaction. Use the supported view operation with the observed idle marker so a new result arriving during viewing is not inadvertently marked read.
10. **Rebind a moved session.** When canonical location changes, restore its project context and refresh location-dependent catalogs, files, and stream filters before subsequent location-dependent actions. A pending move is visible until the server reports its application at the execution boundary; a move does not copy files.
11. **Fix Remote skills without widening the gateway.** Allow the exact V2 skill-list method and route with the same canonical approved-location policy as related catalogs. Preserve errors as errors rather than returning an apparently empty list.
12. **Preserve V1 and V2 delegated work.** Recognize both `task` and `subagent`. Retain validated child-session identifiers and supported running/completed metadata. Project synthetic subagent result entries using their source, child ID, agent, and state. A successful launch-tool result with running metadata remains a running child task. Avoid exposing unrelated raw metadata in product UI.
13. **Update QR helper startup per protocol.** Keep the supported V1 attachment path and use the current V2 root CLI with an explicit server URL and environment-based password. Confirm that the TUI, paired phone, and any helper-started private server have the same identity. The helper may stop only the server process it owns; V2 standalone serve remains a valid startup mode.
14. **Add typed prompt attachments.** Extend prompt input to preserve files alongside text and existing mentions. Phone files use supported data URIs; server repository references use server file URIs and optional start/end lines. Preserve the different input and history attachment shapes. A phone file path must never be interpreted as a server path.
15. **Start with formats the server accepts.** Support UTF-8 text and documented image formats. Prepare iOS photos as an accepted image format such as JPEG or PNG. Account for model input capabilities and reject unsupported formats clearly rather than assuming PDF, HEIC, audio, video, or HTTP attachment URLs are automatically usable.
16. **Validate the complete attachment request.** Include Base64 expansion, JSON, prompt text, and all attachments when evaluating size. The current Remote HTTP body limit is 2 MiB, which leaves less than approximately 1.5 MiB for raw files after encoding and overhead. Compress or downsize supported images within a stated policy, or explain the limit; this specification does not silently increase transport limits.
17. **Preserve file results from tools.** Extend the existing tool-content representation beyond text to retain supported URI, MIME, and filename information, including output attached to a failure. Render supported content with bounded loading and useful unsupported/unavailable states. Fetching or decoding a file result must not block the main actor.
18. **Represent richer timeline entries without forcing them into chat roles.** Preserve the supported V2 entry types and their stable identity, order, and useful metadata. Present contextual changes and completion as compact rows, with fuller displays for results requiring inspection. Unknown entries must not invalidate an otherwise usable page or be interpreted as a fabricated user/assistant message.
19. **Expose active context and compaction.** Add the supported context read and compaction admission operations. Show pending/running/completed compaction and the resulting summary. Keep conversation history, historical token/cost totals, and current context occupancy distinct; show an unknown or unavailable occupancy instead of deriving it from cumulative session tokens.
20. **Support conditional forms through the existing interaction flow.** Decode and evaluate supported `when` predicates, update active fields after answer changes, and validate/submit active fields only. Preserve safe degradation for unknown conditions or field types. Handle supported global MCP form ownership without weakening ordinary session ownership checks.
21. **Use worktree inventory as worktree inventory.** Add supported list/create operations and create the task's session at the returned canonical location. Expose refresh only where useful and supported. Do not equate a remembered folder or ordinary project with a worktree.
22. **Keep fork and file isolation separate.** Fork copies conversation history; worktree creates a separate working directory. The V2 `before` boundary is exclusive, and omitting it copies the supported settled history. Preserve the distinct fork metadata instead of expecting a parent ID. In the researched release, a fork inherits current settings rather than reconstructing historical settings at the boundary.
23. **Move and navigate sessions explicitly.** Offer moves only to authorized destinations and show their control-item lifecycle. Keep child sessions reachable through their parent's activity even if the main catalog filters them out. A combined isolated experiment requires an appropriate worktree and a session located there; a conversation fork by itself is insufficient.
24. **Preserve Remote location and ownership policy.** Every new method and route gets an explicit policy. Validate both current session ownership and a move destination. Newly created worktree locations must follow the existing Mac approval mechanism before access through Remote. Do not allow an entire API prefix or automatically trust directories beneath an approved project.
25. **Add observation of supported background work.** Use the background operation only for supported active tools and show the resulting state plus bounded, paginated output where available. This controls work on the server and makes no promise of iOS execution while the app is suspended. Keep full interactive PTY transport outside this specification.
26. **Extend approvals within their real scope.** Add supported saved-rule listing/removal and optional rejection feedback. Preserve rule action, resource, effect, and ordered evaluation when presenting scope. Remote must enforce the authorized scope of these operations; do not expose global configuration merely because a session is visible.
27. **Make staged revert accurate.** Reuse stage/clear/commit. Explain and preserve the distinction between history-only and file-changing revert. Staging with files enabled can already change the working directory; clearing reverses the staged rollback when supported. New prompt admission can commit an existing staged revert, so the UI must reconcile that transition.
28. **Provide bounded integration diagnostics.** Show supported integration and MCP status and the lifecycle of authentication attempts. Complete an already supported login method through its documented URL or form flow and refresh dependent catalogs afterward. Keep provider credentials, OpenCode pairing credentials, and Remote credentials separate. Do not build a general provider-administration interface.
29. **Extend Review and export through capabilities.** Add supported branch/committed comparison modes with an explicit base where relevant. Offer experimental session export only after determining support, with an unavailable state for other servers. Export is an archive workflow rather than a public share link; import is outside this specification.
30. **Load useful content incrementally.** Fetch the latest supported transcript page for initial display, prepend older pages on demand, and retain ordering, identity, and scroll position. Page/search/filter session lists using the server's supported semantics. Duplicate or invalid cursors remain explicit errors rather than infinite loops or silent partial success.
31. **Keep analytics coverage accurate.** UI paging must not change the meaning of Insights and calendar totals. Preserve a separate complete read or a verified server aggregate; if only partial data is available, identify that coverage. Experimental stats may be used only after availability and metric semantics are checked.
32. **Preserve native navigation and presentation.** Extend existing screens and services rather than adding an alternative root flow. Keep chat tab-bar hiding attached to the connected root navigation stack. Follow project UI skills during implementation and include screenshots of visible changes.
33. **Keep the delivery order explicit.** Finish Stage A before depending on the new session/inbox state in Stage B or C. Deliver incremental-loading and direct/Remote parity improvements with the stage they affect. Stage D follows the reliable core workflows rather than delaying their release for administration features.

## Testing Decisions

1. **Use one existing primary application boundary.** Drive public ChatClient actions and the session, workspace, interaction, and review service interfaces with an injected OpenCodeTransport. Feed realistic HTTP responses and raw SSE data through the production client/adapters, then assert the observable application state and outbound requests that have externally meaningful effects. This covers model selection, inbox, recovery, timeline, forms, and location changes without mocking every decoder or internal helper. The boundary is proposed for user confirmation before issue publication.
2. **Retain the existing Remote boundary.** Extend GatewayIntegrationTests through the production gateway/forwarder with an isolated workspace registry and controlled upstream. Verify that supported direct-client operations also work remotely and that unauthorized session, destination, method, and route access is rejected. These tests cover the additional delivery boundary and must not create a second application-state model.
3. **Verify helper startup at its external boundary.** Build the existing helper and run it against representative supported V1 and V2 installations or controlled executables. Verify the selected server, arguments, authentication source, and owned-process lifecycle. Do not introduce a general process abstraction solely to assert private command-building details.
4. **Test behavior rather than implementation structure.** Good tests describe what a user can do, which canonical state becomes visible, and which unintended server mutation is prevented. Do not assert private method calls, exact task scheduling, view extraction, or lists of decoded fields that merely mirror implementation. Keep narrow contract/safety tests only where wire semantics, unsupported input, or authorization require them.
5. **Reuse established prior art.** Build on V2ReconciliationTests, QueuedPromptTests, OpenCodePaginationTests, OpenCodeV2SessionMutationTests, OpenCodeV2FormTests, OpenCodeV2PermissionTests, StreamToolPartSafetyTests, ReviewServiceTests, OpenCodePairingTests, and GatewayIntegrationTests. Use Swift Testing for additions and retain protocol-selection regression coverage.
6. **Exercise competing-client settings.** Change a session model, variant, and agent externally before a new assistant response exists; refresh the phone and send an ordinary prompt. Assert that the new settings are visible and are not overwritten. Also verify an explicit phone selection followed by a prompt, a failed switch, and a stale switch result after changing sessions.
7. **Exercise real admission semantics.** Admit a prompt with a successful body, lose its response after acceptance, and retry with the same ID. Verify one server task and one displayed pending entry. Restore inbox entries admitted externally, cancel before delivery, promote queue to steer, and reconcile delivery/cancellation races. Verify that interruption does not imply pending-queue deletion. Existing empty or 202-only fixtures must not substitute for the released V2 admission contract.
8. **Exercise recovery and execution boundaries.** Drop the stream while settings, inbox, outcome, and location change. Verify complete restoration, retry after failure, rejection of stale-session results, and resumption of correctly scoped events. Verify that assistant-step completion does not prematurely end a session and that absent active status alone is not reported as success.
9. **Exercise delegated results.** Verify V1 task and V2 subagent presentation, a successful tool launch with a still-running child, and synthetic completion/failure/cancellation. Verify child navigation and pending permission/form ownership. Preserve malformed/unknown metadata safety without discarding a valid parent transcript.
10. **Exercise attachments end to end.** Verify supported phone images/text, repository line references, incoming desktop attachments, tool file output, unsupported formats, and model capability errors. Check the complete encoded body immediately below and above the Remote limit. Confirm with a live supported model that the intended attachment reaches the provider; successful HTTP admission alone is insufficient.
11. **Exercise context and forms.** Verify compaction admission through completion, summary visibility, full-history versus active-context separation, and unknown occupancy. Toggle conditional form branches and assert active-field-only validation/submission. Verify a global MCP form separately from an ordinary session form and keep unsupported predicates explicit.
12. **Exercise workspace and control flows.** Create a worktree and a session in its returned location; fork before a boundary; inspect the separate fork metadata; move at an execution boundary; and repeat through Remote with approved and unapproved destinations. Verify a supported background transition, bounded output, unsupported transition, saved-rule removal, rejection feedback, and staged revert clear/commit behavior.
13. **Exercise paging without corrupting totals.** Open a large transcript and catalog, verify useful initial content without a complete fetch, load older data without duplicates or scroll jumps, and test invalid/repeated cursors. Verify that Insights/calendar still use their declared complete or explicitly partial coverage. Avoid brittle timing thresholds on shared simulator infrastructure.
14. **Keep live acceptance separate from fixture coverage.** Record the exact V2 server version and use anonymized response/event examples from that installation. Run two-client, reconnect, settings-change, inbox, move/fork, forms, and attachment scenarios directly and through Remote. Keep V1 acceptance for the retained workflows. Automated fixtures do not establish provider-level or device-level correctness.
15. **Run the repository-required verification for the actual changes.** App or widget changes require project generation and the full OpenLens test scheme on the configured booted iPhone 18 Pro simulator. QR helper changes require its Swift package build. Remote changes require the gateway integration suite and exercised forwarding. Include screenshots for visible UI changes and state any live scenarios that could not be completed. This specification itself changes no application code and makes no claim that those checks have already run.

## Out of Scope

- Reimplementing V2 support that already works, removing V1 support, or introducing a new ViewModel/Presenter architecture.
- Implementing every OpenCode endpoint or building a general provider, credential, plugin, or server administration console.
- Arbitrary inbox reordering, editing the text of an accepted inbox entry, or guaranteeing atomic settings changes across independently acting clients beyond the server contract.
- Full interactive PTY support and a new PTY WebSocket channel through Remote.
- APNs, guaranteed background delivery, or keeping iOS executing while suspended. Server background work is a separate concern.
- LSP tools or diagnostics, todo parity, and public sharing endpoints absent from the researched V2 public API.
- Treating every model-supported binary format as an OpenCode-supported attachment; native PDF, HEIC, AVIF, audio, and video ingestion is not promised.
- Automatically approving newly created worktree directories or weakening Remote session/location ownership checks.
- Destructive worktree removal, copying files as part of a session move, or claiming that a conversation fork isolates files.
- Session import, plugin RPC execution on iOS, synthetic/instruction/environment authoring for automation, and a general experimental-API interface.
- Replacing global-event recovery with an experimental durable session log. The latter does not replay all global ephemeral state.
- Raising Remote payload limits as a prerequisite for the attachment MVP or exporting signing material, local credentials, or unredacted secrets.

## Further Notes

The reference contract is OpenCode 2.0.23, checked on 2026-10-05. V2 means the OpenCode 2 server and its public `/api/*` contract; the legacy SDK name containing `/v2` is not proof of that server generation. Availability must still be determined for the connected installation.

Images, MCP, forks, undo, worktrees, and background delegation existed in V1 or later V1 releases. This specification addresses the current V2 contracts and the missing OpenLens workflows; it does not describe all of those capabilities as inventions of V2.

The evidence so far is static analysis of the current OpenLens implementation, published API, and released upstream source. The missing Remote skill route, discarded timeline types, V2 subagent naming mismatch, and obsolete QR attachment command are confirmed contract/code gaps. The competing-client model overwrite is a supported risk that still needs the live acceptance scenario described above.

This is one parent specification with ordered delivery stages. Do not mark it complete when only Stage A is delivered. Subsequent implementation tasks should preserve these boundaries and acceptance behavior without treating already implemented core V2 features as new work.

Upstream references:

- [OpenCode migration from V1](https://opencode.ai/v2/docs/migrate-v1/)
- [OpenCode V2 API](https://opencode.ai/v2/docs/api)
- [Public V2 OpenAPI](https://opencode.ai/v2/openapi.json)
- [Attachment contracts](https://opencode.ai/v2/docs/attachments/)
- [Compaction](https://opencode.ai/v2/docs/compaction/)
- [Permission rules](https://opencode.ai/v2/docs/permissions/)
- [Snapshots and staged undo](https://opencode.ai/v2/docs/snapshots/)
- [V2 subagent tool in release 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/tool/plugin/subagent.ts)
- [Background subagent result delivery in release 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/subagent-completion.ts)
- [Inbox admission and idempotency in release 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/inbox.ts)
- [CLI commands in release 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/cli/src/commands/commands.ts)
