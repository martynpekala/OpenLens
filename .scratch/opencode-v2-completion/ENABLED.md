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

Commit: `c345d35`, including the ticket's done status.

- Session rows and the open chat show whether the server's last execution succeeded, failed or was interrupted, along with when it ended.
- Active work, waiting for permission and waiting for a form response have their own chat status. A completed assistant step keeps the session working while server execution continues.
- If execution disappears from the active list without a confirmed result and idle timestamp, the chat shows “Outcome unavailable.” It also prevents an older success from being reused for a newly observed run or published as a successful Live Activity completion.
- Returning to the app, reconnecting after a stream gap and receiving execution events restore the canonical result. A delayed response from a previous chat cannot change the newly opened session.

Verified with 515 passing tests in 55 suites on the dedicated AFK simulator on 2026-10-09. Screenshots show [session outcomes](screenshots/06-session-outcomes.png), [successful execution](screenshots/06-chat-succeeded.png), [failed execution](screenshots/06-chat-failed.png), [interruption](screenshots/06-chat-interrupted.png), [active work](screenshots/06-chat-working.png), [permission waiting](screenshots/06-chat-permission.png), [form waiting](screenshots/06-chat-form.png), and [unavailable outcome evidence](screenshots/06-chat-unknown.png). Remote was removed in `77b72ac`; this ticket follows the current direct-connection scope. A live two-client V2 server session and physical-device Live Activity run remain unverified.

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
