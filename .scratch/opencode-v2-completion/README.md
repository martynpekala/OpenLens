# OpenCode V2 completion tickets

35 approved local tickets: 11 P1, 17 P2, and 7 P3. Each ticket has its own file, acceptance criteria, and explicit blocking edges.

Source: [OpenLens V2 gap analysis](../../OpenLens/Playbook/OPENCODE_V2_OPENLENS_GAP_ANALYSIS.md).

Implementation baseline: OpenLens V2 revision `1dfb5aa` or a descendant retaining the dual-protocol services and Remote isolation. These tickets extend that baseline. Verify it before implementation.

## Work selection

Start with unfinished tickets whose blockers have all been completed. Priority determines which eligible work to choose; numbering records dependency order and does not impose one linear chain. A blocked ticket remains ready-for-agent but must wait for its listed prerequisites.

Initial frontier, before any ticket has been completed:

- **P1:** 01, 02, 05, 06, 08, 09, 10, 12.
- **P2:** 15, 16, 18, 19, 20, 24, 25, 26, 31.
- **P3:** 27, 29, 30, 33, 34.

## Ticket index

| Number | Priority | Blocked by | Ticket |
| --- | --- | --- | --- |
| 01 | P1 | None | [Preserve canonical V2 session model, variant, and agent](issues/01-preserve-canonical-v2-session-model-variant-and-agent.md) |
| 02 | P1 | None | [Confirm V2 prompt admission and retry without duplicate work](issues/02-confirm-v2-prompt-admission-and-retry-without-duplicate-work.md) |
| 03 | P1 | 02 | [Restore the shared V2 session inbox after reconnecting](issues/03-restore-the-shared-v2-session-inbox-after-reconnecting.md) |
| 04 | P1 | 03 | [Cancel pending V2 prompts and promote queue to steer](issues/04-cancel-pending-v2-prompts-and-promote-queue-to-steer.md) |
| 05 | P1 | None | [Use V2 skills through Remote](issues/05-use-v2-skills-through-remote.md) |
| 06 | P1 | None | [Show authoritative V2 execution outcomes](issues/06-show-authoritative-v2-execution-outcomes.md) |
| 07 | P2 | 06 | [Mark newly completed V2 session results as unread](issues/07-mark-newly-completed-v2-session-results-as-unread.md) |
| 08 | P1 | None | [Rebind an open V2 session after its location changes](issues/08-rebind-an-open-v2-session-after-its-location-changes.md) |
| 09 | P1 | None | [Show running and completed V2 subagent tools](issues/09-show-running-and-completed-v2-subagent-tools.md) |
| 10 | P1 | None | [Preserve useful V2 context changes in the timeline](issues/10-preserve-useful-v2-context-changes-in-the-timeline.md) |
| 11 | P1 | 09, 10 | [Deliver background subagent results to the parent history](issues/11-deliver-background-subagent-results-to-the-parent-history.md) |
| 12 | P1 | None | [Open the QR helper TUI against the paired V2 server](issues/12-open-the-qr-helper-tui-against-the-paired-v2-server.md) |
| 13 | P2 | 02 | [Send screenshots and supported photos in V2 prompts](issues/13-send-screenshots-and-supported-photos-in-v2-prompts.md) |
| 14 | P2 | 13 | [Attach text files and repository line references](issues/14-attach-text-files-and-repository-line-references.md) |
| 15 | P2 | None | [Display supported files returned by V2 tools](issues/15-display-supported-files-returned-by-v2-tools.md) |
| 16 | P2 | None | [Inspect the active V2 session context](issues/16-inspect-the-active-v2-session-context.md) |
| 17 | P2 | 03, 10, 16 | [Request compaction and inspect the resulting summary](issues/17-request-compaction-and-inspect-the-resulting-summary.md) |
| 18 | P2 | None | [Complete conditional V2 forms on the phone](issues/18-complete-conditional-v2-forms-on-the-phone.md) |
| 19 | P2 | None | [Reach supported global MCP forms from Inbox](issues/19-reach-supported-global-mcp-forms-from-inbox.md) |
| 20 | P2 | None | [Create a new task in an isolated worktree](issues/20-create-a-new-task-in-an-isolated-worktree.md) |
| 21 | P2 | 01 | [Fork a V2 conversation at a chosen history boundary](issues/21-fork-a-v2-conversation-at-a-chosen-history-boundary.md) |
| 22 | P2 | 03, 08 | [Move a V2 session to another approved location](issues/22-move-a-v2-session-to-another-approved-location.md) |
| 23 | P2 | 09 | [Open child sessions from delegated-work cards](issues/23-open-child-sessions-from-delegated-work-cards.md) |
| 24 | P2 | None | [Observe supported foreground tools after sending them to background](issues/24-observe-supported-foreground-tools-after-sending-them-to-background.md) |
| 25 | P2 | None | [Inspect saved approvals and explain permission rejection](issues/25-inspect-saved-approvals-and-explain-permission-rejection.md) |
| 26 | P2 | None | [Make staged revert understandable and reversible](issues/26-make-staged-revert-understandable-and-reversible.md) |
| 27 | P3 | None | [Diagnose unavailable models and MCP integrations](issues/27-diagnose-unavailable-models-and-mcp-integrations.md) |
| 28 | P3 | 27 | [Complete a supported integration login from the phone](issues/28-complete-a-supported-integration-login-from-the-phone.md) |
| 29 | P3 | None | [Review branch and committed changes with an explicit base](issues/29-review-branch-and-committed-changes-with-an-explicit-base.md) |
| 30 | P3 | None | [Export a session when the server supports it](issues/30-export-a-session-when-the-server-supports-it.md) |
| 31 | P2 | None | [Browse large session catalogs incrementally](issues/31-browse-large-session-catalogs-incrementally.md) |
| 32 | P2 | 10 | [Load the latest transcript before older history](issues/32-load-the-latest-transcript-before-older-history.md) |
| 33 | P3 | None | [Use verified V2 statistics for Insights and the activity calendar](issues/33-use-verified-v2-statistics-for-insights-and-the-activity-calendar.md) |
| 34 | P3 | None | [Preserve model availability and release-status metadata](issues/34-preserve-model-availability-and-release-status-metadata.md) |
| 35 | P3 | 14 | [Find repository files quickly when adding prompt context](issues/35-find-repository-files-quickly-when-adding-prompt-context.md) |

## Scope

Tickets cover session consistency, shared inbox control, Remote skills, execution outcomes, delegated work, QR startup, attachments, context, forms, worktree/fork/move, background observation, permissions, review, diagnostics, export, paging, and selected later improvements.

The following require a separately chosen workflow:

- APNs or guaranteed iOS background delivery.
- A full interactive PTY channel.
- Public share, todo, or LSP parity absent from the researched V2 API.
- Arbitrary inbox ordering or accepted-text editing.
- Automatically approving new workspace locations.
- General provider/plugin administration or plugin execution on iOS.
- Session import, synthetic/instruction authoring, generated prompt suggestions, and experimental durable-log replay without a separately chosen workflow.
