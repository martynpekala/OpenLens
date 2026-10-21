# What each completed ticket enables

What you can do in OpenLens once each ticket is done. Add an entry here when a ticket is marked done.

## 01: Preserve canonical V2 session model, variant, and agent

Commits: `dfdaf23`, marked done in `830c344`.

- When you open or reopen a session, the phone shows the model, reasoning variant and agent the server is actually using. This also works for a new session with no assistant reply yet.
- If you switch model, variant or agent on the desktop, an ordinary prompt from the phone keeps that choice instead of overwriting it.
- If you change a setting on the phone, the server applies it before your next prompt is sent. If the change fails, the prompt isn't sent with the wrong settings.
- Defaults for new sessions stay separate from the settings of existing sessions.

## 02: Confirm V2 prompt admission and retry without duplicate work

Commits: `47d707d`, `14d26dc`, marked done in `2b73675`.

- Each prompt shows whether it is being sent, was accepted, couldn't be confirmed, or failed.
- On a flaky network, a prompt whose response was lost shows "Not confirmed" and returns to the composer. Sending it unchanged is safe: the server never runs it twice or shows it twice.
- A timeout is no longer reported as the server rejecting your prompt, and your input is kept.
- Normal, queued and steering prompts all go through the same confirmed flow.

## 03: Restore the shared V2 session inbox after reconnecting

Commits: `add6e64`, including the ticket's done status.

- When you reopen a session, return to the app, or reconnect after a stream gap, the phone restores pending work accepted by the server, including prompts sent from another client.
- The queue distinguishes prompts still being submitted from accepted work. User prompts, automatic messages, compaction and session moves retain their useful labels, delivery mode and queue position; files attached elsewhere stay visible by name.
- Steering entries appear before queued work. Steered compaction appears before earlier steers when the server gives it priority, while respecting a pending session move.
- When another client admits or cancels work, changes its delivery mode, or the server delivers it, the phone refreshes the same queue. Already delivered entries are not repeated, and separate server entries remain visible even when their text is identical.
- If the queue cannot be recovered, the session is not shown as synchronized. A successful recovery retry restores the queue and clears the recovery error.
- Pending external work survives resetting the open chat. Finishing a reply on the phone does not prematurely promote the next V2 queue entry into the transcript.

Verified with 507 passing simulator tests and a [shared inbox screenshot](screenshots/03-shared-v2-session-inbox.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server run remains unverified.

## 04: Cancel pending V2 prompts and promote queue to steer

Commits: `5d7ee85`, including the ticket's done status.

- From an accepted user prompt's actions menu, you can cancel pending work, including prompts sent from another client.
- You can promote a queued prompt to "Steer at next step" using its existing server identity. The phone does not resend its text as a new prompt.
- After either action, the phone refreshes the shared queue and transcript. If a response is lost, recovered server state can confirm the change. A prompt delivered during the action appears in history instead of remaining in the queue.
- Failed actions leave pending work available to retry. Duplicate taps are blocked while an action is in progress, and a delayed result from the previous session cannot change the newly opened session.
- Stopping the active reply preserves remaining pending work. Pending user prompts have individually accessible menus; automatic messages, compaction and session moves keep their existing presentation.

Verified with 519 passing simulator tests, separate standards/spec reviews, and simulator use of both actions against a local V2 fixture. Screenshots show the [actions menu](screenshots/04-pending-prompt-actions.png) and [the queue after promotion](screenshots/04-promoted-prompt.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server run remains unverified.

## 06: Show authoritative V2 execution outcomes

Commits: `c345d35`, corrected after review in `78e5e40`, including the ticket's done status.

- Session rows and the open chat show whether the server's last execution succeeded, failed or was interrupted, along with when it ended.
- Active work, waiting for permission and waiting for a form response have their own chat status. A completed assistant step keeps the session working while server execution continues.
- If execution disappears from the active list without a confirmed result and idle timestamp, the chat shows “Outcome unavailable.” It also prevents an older success from being reused for a newly observed run or published as a successful Live Activity completion.
- Returning to the app, reconnecting after a stream gap and receiving execution events restore the canonical result. A delayed response from a previous chat cannot change the newly opened session.
- Session rows reread the server's result when a run ends, when the list returns or foregrounds, and when you change the selected chat in the iPad sidebar. A failed result read keeps the row visible with “Outcome unavailable” and retries; a failed status fetch retains the last known active statuses.
- If another client answers a permission or form and the run ends before the phone clears the request, the Live Activity still ends with the canonical result or is dismissed when the result is unavailable. Malformed advisory outcome/idle fields leave the session visible with unavailable evidence.

Verified after review with 525 passing tests in 56 suites on the dedicated AFK simulator on 2026-10-09. Screenshots show [session outcomes](screenshots/06-session-outcomes.png), [a freshly recovered result](screenshots/06-refreshed-session-outcomes.png), [a failed result read](screenshots/06-failed-outcome-refresh.png), [successful execution](screenshots/06-chat-succeeded.png), [failed execution](screenshots/06-chat-failed.png), [interruption](screenshots/06-chat-interrupted.png), [active work](screenshots/06-chat-working.png), [permission waiting](screenshots/06-chat-permission.png), [form waiting](screenshots/06-chat-form.png), and [unavailable outcome evidence](screenshots/06-chat-unknown.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server session, physical-device Live Activity run, and manual iPad selection exercise remain unverified; the selection recovery is covered at the service boundary.

## 07: Mark newly completed V2 session results as unread

Commits: `dc47a29`, corrected after AFK reviews in `c19246a` and `00abfff`, including the ticket's done status.

- Completed V2 results show an Unread badge until the server confirms that completion was viewed. Active work keeps its working indicator; changing a title does not make a result unread.
- Opening a synchronized chat in the foreground acknowledges the displayed completion. Each newer completion you watch in that chat also gets acknowledged, with one request in flight and the latest displayed marker next. An older request cannot mark an unseen newer completion read.
- Switching to Workspace or Review stops viewing observation, even while the app stays in the foreground. Returning to the on-screen chat restarts a cancelled acknowledgement without requiring its session to change.
- A lost response is checked against canonical server state. Re-syncing the transcript preserves an in-flight acknowledgement. If viewing cannot be confirmed, the result stays unread and the chat offers Try Again, even if another operation also fails. Confirmed retry or later confirmation clears the viewing error.
- Confirmed viewing immediately clears the matching list/sidebar badge, including while the chat stays open. An older poll cannot restore it, and a delayed acknowledgement cannot replace a newer result or change a different chat.
- Refreshing or returning to the list restores shared desktop/phone read markers. Every 30 seconds while the foreground V2 list stays visible, only unread inactive rows reread their markers, with at most four concurrent requests. A failed attention read preserves the result and waits for another attention refresh. Desktop viewing events recover only session info without reloading the open chat's transcript, inbox, permissions or forms.
- If refresh discovers a newer completion still unread on the server, its newer idle marker replaces the stale row before merging read markers, so an older viewed result cannot hide it. Send and other operation errors show with Dismiss ahead of a viewing error; dismissing them reveals its retained Try Again action.
- V1 behavior and chat tab bar hiding are preserved.

Verified after the second review with **582 passing tests in 59 suites** on the dedicated AFK simulator on 2026-10-09. Ticket 07 now has 26 Swift Testing tests, including hosted sequential completions, re-sync during POST/canonical reread, hidden-tab foreground recovery and return after cancellation, typed error priority/dismissal/retry, immediate row marker propagation, stale idle/polls, a 200-read-row refresh exclusion and marker-only event request checks. Screenshots show [unread results](screenshots/07-unread-results.png), [viewed results](screenshots/07-viewed-results.png), [unconfirmed viewing with retry](screenshots/07-view-acknowledgement-failed.png), and [a send error with Dismiss while viewing is also unconfirmed](screenshots/07-send-and-view-acknowledgement-failed.png); both error screenshots were captured from the second-review build. This supersedes the original 572-test and first-review 578-test verification and once-per-visit policy. The suspected hidden-tab regression did not reproduce before the explicit visibility guard on this simulator; both tab directions now have hosted coverage. Live two-client server/device behavior and manual iPad/poll-timer interaction remain unverified; transport, row merging, refresh selection and foreground/on-screen chat behavior are covered with injected fixtures. Remote and its gateway were removed in `77b72ac`.

## 08: Rebind an open V2 session after its location changes

Commits: `8fee5d0`, corrected after AFK review in `2dba41c`, with post-commit cancellation and queued-command recovery fixed in `b3ac488`, including the ticket's done status.

- When another client moves your open session, the phone rereads its canonical location and restores the new project, branch, model catalog, commands, skills and files. Your conversation, typed draft and inline phone attachments stay with the session.
- Location-dependent requests use the restored directory. Prompts retain the same server session ID; the server owns their execution location. Successful recovery clears old repository attachment references and composer selections and resets the Workspace browser to the new root. Obsolete responses cannot replace the recovered chat or workspace.
- Move events can reach the open chat from either directory; another session's move is ignored. Canonical recovery and explicit session loading follow the latest location. Returning to an already loaded chat destination preserves its current binding and respects a refused handoff instead of restoring a stale navigation value.
- An SSE reconnect during project metadata recovery still completes attachment cleanup and model reload. Moving back to the original directory while another catalog is loading also restores the correct models.
- If the server refuses the new location or canonical recovery fails after a known move, the chat keeps your draft and conversation, shows an explicit error with Try Again, and blocks new work until recovery succeeds. It never starts using an event's unverified destination.
- Cancelling a handoff leaves an explicit retry state. Try Again restores project name, current project, branch and models even when the new directory had already committed before cancellation. During a failed handoff the header shows the bound project and branch, with the requested destination explained in the error.
- If a move interrupts work waiting to be sent, the phone restores unsent prompt or command text and inline phone files, drops stale repository references from restored attachments, and asks you to review and retry. It does not automatically forward that work. An interrupted queued command leaves the existing response generating, keeps loading active and preserves its Live Activity.
- This observes moves initiated elsewhere. Initiating a move from the phone remains ticket 22.

Verified after both reviews with 546 passing tests in 57 suites on the dedicated AFK simulator on 2026-10-09. Ticket 08 has 20 tests with 59 cases, including real SSE parsing/filter/reconnect callbacks over an injected stream transport, navigation restoration, cancelled recovery (including nine post-commit metadata/model cancellation cases), and ten settings-wait/send cases that also assert active response and Live Activity preservation for queued work. Screenshots show [the rebound chat and command catalog](screenshots/08-rebound-chat.png), [the restored Workspace project and branch](screenshots/08-rebound-files.png), [a refused rebind with its bound header and retry](screenshots/08-rebind-failed.png), [restored unsent text and an inline phone file](screenshots/08-unsent-move.png), and [a restored queued command alongside the running response](screenshots/08-queued-command-move.png). This supersedes the original 538-test completion claims and the earlier 545-test repair verification. A live V2 server/two-device move or prompt execution and manual iPad navigation remain unverified; raw stream behavior and the navigation service helper are covered through injected transports. Remote and its gateway were removed in `77b72ac`, so this follows the current direct-connection scope.

## 09: Show running and completed V2 subagent tools

Commits: `7e179e6`, including the ticket's done status, corrected after review in `c030ad8`.

- Legacy `task` tools and V2 `subagent` tools show the same delegated-work cards in streamed and reopened conversations.
- Cards preserve child state reported by tool progress/results. A successful background launch shows Working after the parent's reply ends. Done applies when completion is reported in the tool result itself; failed calls show Error.
- Background cards do not follow later child completion yet. With only launch-time running evidence they remain Working, including the shimmer and after reopening history, even once the child finishes. Ticket 11 must deliver the later synthetic result.
- A launch with a known tool state shows a Subagent card before its agent or task details arrive. Its Working label remains visible even without a detail line. An unknown tool status without useful details stays hidden instead of inventing a Working card.
- Unknown or malformed child metadata leaves the tool and transcript readable. Supported status values and validated child-session identifiers survive stream safety preparation; unsafe identifiers are dropped rather than shortened or used as session links.
- Permissions and forms from linked children retain their owning session. Unrelated requests and links from a previous parent do not become requests for the newly opened chat.
- Later delivery of synthetic background results remains ticket 11; opening child conversations remains ticket 23.

Verified after review with 556 passing tests in 58 suites on the dedicated AFK simulator on 2026-10-09, including parent-turn completion followed by child permissions/forms and malformed native V2 progress/success metadata. Screenshots show [Working, Done and Error cards](screenshots/09-subagent-tools.png), [a launch before input arrives](screenshots/09-subagent-pending.png), and [an unknown status without an invented Working card](screenshots/09-subagent-unknown.png), with the chat tab bar hidden. No live V2 server/two-device run, physical-device run or manual iPad navigation was performed. Remote and its gateway were removed in `77b72ac`, so this follows the current direct-connection scope.

## 13: Send screenshots and supported photos in V2 prompts

Commits: `c685bb2`, marked done in `b61ed5a`.

- From the composer you can attach photos and screenshots (PNG, JPEG, GIF, WebP and HEIC), preview them, remove them, and send them with your prompt.
- HEIC and other iOS formats are converted to formats the server accepts, and large images are resized to fit the request limit.
- If the selected model doesn't accept images, or the attachments are too large, you get a clear error before anything is sent.
- Images you send, and images from the desktop or from history, stay visible in the chat.
- Not yet verified: a live model receiving the image, both directly and through Remote.

## 14: Attach text files and repository line references

Commits: `bf3136c`, marked done in `13b7293`.

- **Text files from the phone:** use Attach → Files to add UTF-8 text, Markdown or source files. Tap a chip to preview the file, remove it, and send it with your prompt.
- **Repository files:** use Attach → Repository File to browse the session's folder on the computer. Pick a file and optionally a line range, like "lines 12–20" or "from line 5 to the end", so the agent reads just that part from the server.
- Phone files and server files are kept separate. A file outside the session's folder, a phone path or a web URL can't be referenced.
- Attachments still show up correctly after a retry or a history reload.
- Errors say what went wrong:
  - a binary file
  - an oversized file
  - a file that couldn't be read
  - an invalid line range
  - a range past the end of the file
  - the server rejecting a file
- **Through OpenLens Remote:** prompts and commands can only reference files inside the session's approved folder. Requests that try to get around this check are refused.
- Limitations:
  - A prompt still needs text.
  - Repository file chips can only be previewed in the picker.

## 15: Display supported files returned by V2 tools

Commits: `dbc37f0`, marked done in `cb1a25c`.

- **Files from tools:** when a tool returns a file, such as a screenshot from read, an MCP or browser tool image, a text file or a PDF, it now appears under that tool's row in the chat.
  - Images show as thumbnails.
  - Text and PDF files show as chips.
  - Tap either to open a preview.
- **Failed tools:** a failed tool still shows the output it produced before the error ("Output before the error:") and any files it returned.
- **Files that can't be shown** stay listed, with the reason:
  - "Too large to show here"
  - "No preview" for an unsupported type
  - unavailable, for a web URL
  - "N more files not shown" for files past the per-tool limit
- **Through OpenLens Remote:** a large tool image no longer breaks the event stream or a history page. Direct and Remote connections show the same files.
- Limitations:
  - Withheld files can't be fetched on demand.
  - Server files open only inside the session folder, up to 8 MiB.

## 10: Preserve useful V2 context changes in the timeline

Commits: `f6e020b`, including the ticket's done status, corrected after review in `4ceb5bd` and `569b10c`.

- Your conversation now shows model, agent and location changes, system updates and activated skills in their original position, as compact context rows.
- You can expand rows to read previous selections/location, system instructions and skill text. Saved shell results expose readable multiline output, exit codes and a server truncation note; compaction rows expose the saved summary, recent context and failure details.
- Large detail previews stop at 40,000 characters and say “Preview shortened.” Server truncation remains visible too.
- Wrapped context titles and summaries align to the leading edge in standard and retro chat, including long commands and paths in disclosure controls.
- Retro chat uses its existing pixel fonts and ink on paper for context rows and disclosures, including with dark system appearance.
- Delivered compaction appears once in history even when a stale inbox snapshot still lists it as queued or steering work.
- Idle entries show where an execution succeeded, failed or was interrupted. Unknown outcomes keep a neutral completion label.
- Refreshing, reconnecting and receiving context changes from the desktop restore the same ordered history without duplicate rows. Overlapping pages retain the latest record in its original position, and unknown entry kinds leave the rest of history usable.
- Load earlier history restores older context alongside messages and tool results. A staged revert hides both at the same canonical boundary. Streaming text keeps its live object while refresh places it between canonical context rows, without duplication; an unavailable revert boundary still hides later chat and context IDs. Existing V1 chat and chat tab bar hiding remain available.

Verified after review with **597 passing tests in 60 suites**, including seven new tests for inbox delivery, shell output, preview limits, reverts and live ordering, on the dedicated AFK simulator on 2026-10-09. Screenshots show [context changes](screenshots/10-context-changes.png), [compact results alongside a reply](screenshots/10-context-results.png), [expanded shell/compaction details](screenshots/10-context-details.png), [standard dark-mode details](screenshots/10-context-details-dark.png), [retro dark-mode results](screenshots/10-context-retro-dark.png) and [context changes](screenshots/10-context-retro-changes-dark.png), and [the shortened preview with both notices](screenshots/10-context-shortened-details.png). Live two-client server and physical-device behavior remain unverified; injected transport/native-event tests and simulator captures cover the implemented behavior. Per-token compaction summary updates, compaction admission, active-context inspection, shell output paging/PTY and synthetic background-child delivery remain outside this ticket. Remote and its gateway were removed in `77b72ac`.

The final alignment correction passed all **597 tests in 60 suites** on 2026-10-09. Recaptured [retro context changes](screenshots/10-context-retro-changes-dark.png) and a [standard wrapping shell command](screenshots/10-context-wrapping-summary.png) confirm leading alignment in the verified simulator build.

## 11: Deliver background subagent results to the parent history

Commits: `349a87e`, including the ticket's done status, corrected after review in `4dd51c8`.

- You can read a background child's completed, failed or cancelled result in the parent conversation before another assistant reply arrives. The result shows its agent, task and readable text; expand it for selectable details.
- The matching delegated-work card changes from Working to Done, Error or Cancelled. Unrelated cards keep their own state, and an old outcome does not complete a later launch of the same child session.
- Repeated events and overlapping history pages update the same canonical result instead of adding duplicate notifications. Reopening the chat or recovering a missed event restores the result from saved server history.
- While a result awaits delivery in the shared inbox, you can read its text, agent and known outcome without seeing the raw wrapper. Its label says “awaiting delivery”; the launch card changes when saved history confirms delivery. A stale inbox response does not duplicate an already delivered result.
- Unknown sources and child states remain neutral, readable context updates. Malformed metadata or invalid child IDs do not complete unrelated work or hide the parent conversation.
- Collapsed result previews and their accessibility text stay short; expanded details retain selectable text within the existing preview budget. Pending results also use a short preview. Results work in standard and retro chat and respect the same revert boundary as the rest of history. Existing V1 behavior and chat tab bar hiding remain available.

Verified after review with **614 passing tests in 61 suites** on the dedicated AFK simulator on 2026-10-09. Ticket 11 now has 17 tests, including Working-to-Done recovery without a live event through synchronization and unload/reopen, pending-result delivery in both inbox modes, unrelated observable projections staying unchanged, consistent conflicting child aliases, and bounded Unicode previews. Screenshots show [completion](screenshots/11-completed.png), [failure](screenshots/11-failed.png), [cancellation](screenshots/11-cancelled.png), [neutral unknown entries](screenshots/11-unknown.png), [expanded details](screenshots/11-details.png), [retro chat](screenshots/11-retro.png), [a result awaiting delivery](screenshots/11-queued-result.png) and [a short collapsed preview](screenshots/11-short-preview.png). The last two captures use the review build. The pinned V2 contract was checked against upstream source; live-server, physical-device, manual VoiceOver and Instruments behavior remain unverified. Guaranteed iOS background delivery is outside this backlog; opening child conversations remains ticket 23. Remote and its gateway were removed in `77b72ac`.

## 12: Open the QR helper TUI against the paired V2 server

Commits: `f0fe64a` closes the ticket as superseded by `77b72ac` (removal of bundled tools and OpenLens Remote).

- You can continue pairing the phone with upstream `opencode pair`, by scanning or pasting its link. OpenLens preserves that server's origin and saves its credentials for direct connections and retries. Legacy direct QR links and V1/V2 connection negotiation remain available.
- This closure adds no new runtime capability or TUI launcher. The deleted `openlens-qr` package, its server process ownership and shutdown behavior no longer apply; the ticket records each retired criterion. Standalone `opencode serve` remains the documented server setup.

Verified with **614 passing tests in 61 suites**, zero failures or skips, using the full AFK verify wrapper on 2026-10-09. Existing Swift Testing coverage checks pairing origins/credentials and secret-safe errors, V1/V2 HTTP/SSE routing, removal of legacy Remote profiles and chat navigation. No app code or visible UI changed, so no screenshots or new tests were needed. Live upstream V1/V2 CLI/TUI startup, shared-service identity/shutdown and physical-device pairing were not verified; this completion does not claim those checks or a build of the removed package.


## 16: Inspect the active V2 session context

Commits: `5b386f1`, including the ticket's done status, corrected after review in `ebc56f4`.

- Tap **Context** beside the chat's model controls to read the selected V2 session's current server projection in a native sheet, separately from the full conversation.
- Read supported messages, instructions, skills, shell/tool results and saved compaction summaries using the existing chat and context disclosures. Unknown entry kinds leave the supported content readable.
- Read or retry active context even when chat synchronization has failed. Refresh with the toolbar or pull-to-refresh. The sheet also reloads when the selected session, its model/location or canonical history changes. Delayed successes and errors from a previous session, binding or connection cannot replace the current view.
- Loading, an empty projection, unavailable support and retryable failures have explicit states. **Try Again** preserves the server's error reason and reads the current projection again. An internal binding change with the same selected session shows an actionable “Context changed” error instead of leaving a spinner. Actual superseded tasks/scopes remain discarded.
- The previous V2 percentage ring has been **removed**. The Context inspector now explicitly shows **Occupancy unknown**, including after disconnect. The gap analysis allows a last-request indicator with an applicable model limit; this ticket conservatively shows unknown because retained reply usage is not verified as belonging to the current projection after context/model changes or compaction. Existing V1 usage presentation and full conversation history remain available.
- Active context, paged history and screenshot fixtures share projection/conversion rules. Duplicate IDs retain their first position and latest value, so the inspector renders each supported entry once.
- Chat tab bar hiding remains on the existing navigation stack. Reading context does not request compaction; that remains ticket 17.

Verified with **627 passing tests in 62 suites**, zero failures or skips, on the dedicated AFK simulator on 2026-10-09. Thirteen Swift Testing tests (37 cases) cover production service/transport behavior, selected-session routing, stale successes/errors, retry while chat remains unsynchronized, no-change held-read controls, duplicate IDs, V1 preservation and unknown occupancy. Screenshots show [the Context button](screenshots/16-context-button.png), [active context from the repair build](screenshots/16-active-context-review.png), [loading](screenshots/16-context-loading.png), [failure and retry](screenshots/16-context-failed.png), [a client-only change with Try Again](screenshots/16-context-changed.png), [unavailable support](screenshots/16-context-unavailable.png), [empty context](screenshots/16-context-empty.png), [retro](screenshots/16-context-retro.png) and [dark appearance](screenshots/16-context-dark.png). Live two-client/server, physical-device, manual iPad/VoiceOver/Dynamic Type and provider-checkpoint behavior remain unverified. Remote and its gateway were removed in `77b72ac`; direct session/location isolation is retained.


## 17: Request compaction and inspect the resulting summary

Commits: `a03c92f`, including the ticket's done status, corrected after AFK verification in `fa0e3e7` and compaction review in `5814d36`.

- Open **Context** in a V2 chat and tap **Compact Conversation** to request a summary at the next step boundary. The inspector distinguishes requesting admission, accepted pending work, running compaction and the terminal result.
- See accepted compaction in the shared inbox and its canonical result in the timeline. Closing/reopening the inspector, reopening the session or reconnecting restores server work without submitting it again. Pending/running requests disable the control.
- Inspect the completed summary and retained recent context in the refreshed active-context view. Completed summary disclosures initially expand; full history remains in Chat. Refresh and pull-to-refresh also recover operation status.
- Read the failure reason or distinguish an associated interrupted execution. An unconfirmed admission can be checked with Refresh or explicitly retried with the original request identity; if recovery finds admitted/completed work, the retry is withdrawn. Unknown server result statuses expose no active retry.
- Later automatic or other-client compaction results replace resolved local work and older local failure/uncertainty. A completed request cannot return to pending or regain its retry identity. Cancellation elsewhere or a staged revert restores the available control after synchronization; an explicit new request uses a fresh ID.
- On a negotiated V2 connection, **Compact Conversation** is initially active after Chat synchronizes. The first request detects endpoint unavailability if it returns bare HTTP 404/405/501, then shows **Compaction unavailable** and remembers that result across sessions for that connection. Known V1 servers are unavailable immediately. Disconnected or unnegotiated connections instead show **Reconnect and refresh Chat before requesting compaction** with a disabled button; structured session errors and provider/network failures remain distinct. Chat tab bar hiding is preserved.

Verified with **648 passing tests in 63 suites**, zero failures or skips, using the full AFK verify wrapper on 2026-10-09 (`build/afk-logs/20261009-151720-tests-1.log`). The compaction suite now has **21 Swift Testing tests (34 cases)** exercising production service/transport behavior, lifecycle events, restoration, stable admission/retry identities, held-request isolation, later automatic/other-client results, cancellation/revert, failed inbox recovery, disconnected guidance, unavailable support and V1 routing. The review regressions reproduced stale pending, resurrected retries and failure reasons, and disconnected-as-unsupported before their fixes. Screenshots show [the request control](screenshots/17-compaction-ready.png), [the shared inbox](screenshots/17-shared-inbox.png), [the timeline summary](screenshots/17-timeline-summary.png), [the resulting active context](screenshots/17-compaction-completed.png), [failure](screenshots/17-compaction-failed.png), [interruption](screenshots/17-compaction-interrupted.png), [unconfirmed admission](screenshots/17-compaction-uncertain.png), [unavailable support](screenshots/17-compaction-unavailable.png), and [disconnected reconnect guidance](screenshots/17-compaction-disconnected.png); the ticket links the remaining submitting/pending/running/retro captures and records each review correction and decision. Live two-client/server, provider checkpoint, physical-device, manual iPad/VoiceOver/Dynamic Type and dark-appearance runs remain unverified. Remote and its gateway were removed in `77b72ac`; direct session/client isolation is covered.


AFK verification repair for ticket 17: rapid visible V2 completions are acknowledged serially with their own observed markers, so a third result cannot remain unread because acknowledgements retriggered SwiftUI's per-frame observation guard. Chat's observation key now tracks completion/synchronization/visibility inputs while the existing service owns confirmed viewed-marker updates. The original hosted-view timeout was reproduced before the fix; its regression now runs ten rapid-completion cases without extra sleeps or increased timeouts. The complete viewed-marker suite passed 26 tests (39 cases), and final full AFK verification passed **642 tests in 63 suites** on 2026-10-09 with zero failures/skips and no result-observer loop diagnostic (`build/afk-logs/20261009-145943-tests-1.log`). Ticket 17 records the finding and correction. Layout and controls are unchanged, so its existing screenshots remain applicable.

## 18: Complete conditional V2 forms on the phone

Commits: `05833e2`, including the ticket's done status and screenshots, corrected after review in `691f698`.

- You can complete supported conditional V2 forms in the native phone form from Chat or Inbox. Fields appear and disappear as earlier string, numeric, Boolean or multiselect answers change.
- An optional Boolean without a default visibly starts **Not answered**. Choose **No** or **Yes** to activate its matching branch, or clear it back to unanswered. The submitted answer matches that choice.
- Switching branches keeps your local draft for when you return. Inactive required fields do not block Submit, and their previous answers never travel in the reply or activate another hidden branch.
- Active fields keep their input constraints and external-action acknowledgements. Recovery and retries use the form's owning session, even when the selected location differs.
- Unknown or malformed predicates, invalid references (including static hidden-field dependencies) and future field types show the OpenCode fallback and disable Submit.

Verified after review with **660 passing tests in 63 suites on 2026-10-09**, including 18 form tests with service/transport, native-event admission and hosted SwiftUI coverage. Screenshots show the [release branch](screenshots/18-conditional-active.png), [waiting branch](screenshots/18-conditional-waiting.png) [unsupported fallback](screenshots/18-conditional-unsupported.png), and [the explicit unanswered Boolean](screenshots/18-boolean-unanswered.png). The hosted regressions poll for actual UI updates and exercise the real Submit action and exact reply payloads. Conditional external fields remain unsupported because the pinned V2 schema has no external `when` and the server requires unconditional acknowledgement; the ticket records the contract evidence and service coverage. Final result log: `build/afk-logs/20261009-202133-tests-1.log`. Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. Live V2 server, physical-device, iPad and enlarged Dynamic Type verification remain unperformed.

## 19: Reach supported global MCP forms from Inbox

Commits: `3b9d410`, including the implementation, ticket's done status, tests and screenshots, corrected after review in `41b2798` and `c617c1a`.

- Open Inbox from Review or Workspace to find **Global MCP forms** separately from ordinary session forms. Each global interaction shows its workspace; pending forms also activate Review's Inbox indicator.
- Complete supported MCP fields in the native form, acknowledge supported external actions, or cancel the interaction. Unknown fields or predicates keep the explicit OpenCode fallback with Submit disabled; cancellation remains available.
- Opening a chat in another workspace keeps pending global forms from the workspace being left reachable in Inbox, Review's Inbox indicator and Micro's form list, even if Inbox never loaded there. The connection queues each departed directory for a recovery check. Each reload reads the selected workspace, departed directories and remembered global-form locations, keeping only global forms from extra locations. Ordinary forms from another workspace do not carry over. Forms with the same wire ID in different workspaces remain distinct.
- Replies and cancellation use the recovered server-resolved workspace. Both Inbox and Micro clear a pending Chat form only when ID and owner match; global events cannot open or clear Chat's form sheet, including before a chat is selected.
- Refresh after a failed Inbox read and retry failed replies or cancellation through the existing flow. Failed location reads retain remembered global forms and recovery candidates with a warning; a successful read with no pending global forms forgets that location. Discovery uses the active location, departed locations from this connection and recovered canonical form locations. It does not scan the workspace catalogue or persist locations across connections.
- After a successful reply or cancellation, the answered form leaves memory and subsequent loads start a fresh read. Reads started before that operation cannot return or save their stale forms; their callers retry in the new revision. Failed operations leave the form available for retry.

Verified after both reviews with **673 passing tests in 63 suites on 2026-10-09**, zero failures or skips, using the full AFK verify wrapper (**VERIFY RESULT: PASS**). The form suite now has **31 tests**: the original seven additions cover service/transport routing, ownership, failures/retries, native-event isolation, safe fallback, forged/unbound locations, route safety and V1 preservation; four first-review regressions cover rediscovery after the production Chat workspace-restoration path, exact reply/cancel location queries, foreign-session exclusion, location retirement, owner-aware de-duplication, failed reads, overlapping loads and canonical-location cache replacement. Two second-review regressions prove discovery after a Chat switch with no prior Inbox load and held-response invalidation across successful reply and cancellation (both parameter cases). The original path-only fixture now answers by requested directory, and the latest tests close the first-load and stale-read gaps left by the first review. This result supersedes the 667- and 671-test verifications. Screenshots show [a departed workspace's global form alongside the current ordinary form](screenshots/19-departed-workspace-inbox.png) from the final verified build, [retained global forms in distinct workspaces](screenshots/19-remembered-inbox.png), [a remembered global alongside the current workspace's ordinary form](screenshots/19-remembered-only-inbox.png), [separate Inbox sections](screenshots/19-inbox.png), [a supported global form](screenshots/19-global-form.png), [external acknowledgement](screenshots/19-global-external.png), [the unsupported fallback](screenshots/19-global-unsupported.png), and [the form-driven Inbox indicator](screenshots/19-inbox-indicator.png). The screenshots illustrate the UI; the service/transport tests establish workspace switching and resolution ordering. Final result log: `build/afk-logs/20261009-211231-tests-1.log`. Micro's owner guards were inspected and build-verified; a hosted Micro submit/cancel ID-collision interaction was not run, and Micro is absent from the current compact TabView. Remote/gateway were removed in `77b72ac`. Live MCP/server or two-client interaction, actual integration login, physical devices, iPad, VoiceOver, enlarged Dynamic Type and dark appearance remain unverified.

## next-workflows/12: Explain why you deny a permission request

Commits: not committed yet (implemented 2026-10-21, working tree on `main`).

- In the permission sheet, **Deny with a reason** opens a short note field. **Send denial** rejects the request and passes the note to the agent through the owning session's reply, so it can adjust its next step without a separate prompt.
- Plain **Deny** works as before. A blank note is not sent. If sending fails, the typed reason stays in the sheet for a retry.
- The option appears only on V2 servers; V1 replies never include the unsupported field.

## next-workflows/01: Open a subagent's conversation from its card

Commits: not committed yet (implemented 2026-10-21, working tree on `main`).

- Delegated-work cards and subagent result rows that name a child session show **Open conversation**. It pushes the child chat onto the current tab; Back returns to the parent.
- The child opens only after the server confirms it exists and belongs to the open parent. A missing child, a session from elsewhere, an invalid identifier and a transport failure each show their own message instead of an empty conversation. A late response after you leave the parent does nothing.
- Unsent composer text is now kept per session: moving between parent and child (or any two sessions) restores each draft and never carries one into the wrong conversation. Attachments are still cleared on switch, as before.

## next-workflows/04 (with 05): Search files to attach and retry the skill catalog

Commits: not committed yet (implemented 2026-10-21, working tree on `main`).

- The repository attachment picker has a search field at its root. It uses `fs.find` in the session's folder and lists matching files with their paths in the server's ranking; choosing one opens the existing preview and line-range flow. Files inside dot-folders are hidden, as when browsing.
- Search matches names and paths, not file contents, and says so when nothing matches. No results, a failed search (with **Try Again**) and a server without search are distinct states; clearing the query returns to folder browsing. A late result for an older query is ignored.
- Typing `@` after a failed skill-catalog request shows **Couldn't load skills** with **Retry** instead of looking like an empty catalog. Retry keeps the draft and attached skills; a catalog already loaded for the location stays usable.

## next-workflows/14: Catch up on a session without changing it

Commits: not committed yet (implemented 2026-10-21, working tree on `main`).

- A **Catch up** chip in the chat header (V2 sessions with messages) opens a sheet with **Summary** and **Next step**. **Generate** calls `session.generate`; the text is shown outside the transcript and can be copied or regenerated.
- Nothing is added to the conversation, no prompt is admitted and no compaction runs. Reopening the sheet shows the cached result without calling the model again; a result older than the transcript is marked as stale.
- A failed regeneration keeps the previous result and shows the error. A result that arrives after you switch sessions stays with the session that asked for it. The sheet labels the text as model output with token cost, not session status.

Verification for the four entries above: Swift Testing through public ChatClient/service actions with injected HTTP transports (`OpenCodeV2PermissionTests`, `V2ChildSessionNavigationTests`, `RepositoryFileSearchTests`, `V2SessionSummaryTests`), plus the full suite via `./scripts/test-ios.sh` on the local iPhone 18 Pro simulator (`49C08F47-0325-4C9E-A7FE-7AD7016CBEBD`; the UUID configured in the script does not exist on this machine). Per the approved scope, no UI automation, screenshots or live OpenCode server checks were run.
