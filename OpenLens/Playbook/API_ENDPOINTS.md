# OpenCode Server API Endpoints

All endpoints are relative to the server base URL (e.g. `http://192.168.1.50:4096`).
Authentication uses HTTP Basic Auth via the `Authorization` header when a password is configured.

## Runtime protocol negotiation

OpenLens does not infer compatibility from a version threshold. At connection
time it first requests `GET /api/info`:

| Result | Selected protocol | Follow-up |
|---|---|---|
| Valid v2 server-info document | v2 | Use `/api/*` routes and `/api/event` |
| `404` or `405` | v1 | Probe `GET /global/health`, then use legacy routes and `/event` |
| Any other transport, auth, or payload failure | None | Surface the failure; do not silently downgrade |

Both direct and Remote Access connections follow the same negotiation. The
Remote relay forwards only its explicit allowlist, including both
`/api/info` and `/api/session/active`.

### v2 conventions

- Location-scoped routes use `location[directory]`. Session lists instead use
  `directory`, and session creation sends `{location:{directory}}` in its JSON
  body. Session-owned routes do not take a location query.
- The relay validates and injects the approved location into session creation.
  Session-owned requests require a fresh canonical ownership lookup. Global
  snapshots and bounded native event frames are filtered against the current
  workspace registry. `/api/event` receives no directory query; the app also
  filters native events to the selected directory. See
  [the v2 audit](../../.scratch/api-v2-regressions/AUDIT.md).
- Most v2 projections use `{ "data": ... }`; location-aware projections also
  include `{ "location": ..., "data": ... }`.
- Non-2xx v2 responses with an OpenCode error document are surfaced as a typed
  `OpenCodeError.apiError`, preserving `_tag`, `message`, `kind`, `field`,
  `resource`, `service`, and `ref`.
- The v2 active snapshot is sparse: `GET /api/session/active` returns only
  running sessions. OpenLens maps every returned entry to its `busy` UI state;
  an omitted session is not busy.

| Capability | v1 | v2 |
|---|---:|---:|
| Todo list | `GET /session/:id/todo` | Unavailable; OpenLens shows no todo control and never calls the v1 route |
| Session sharing | `POST /session/:id/share` | Unavailable; OpenLens returns a clear unavailable-feature error and never calls the v1 route |
| Synchronous prompt | `POST /session/:id/message` | Unavailable; v2 uses asynchronous prompt admission |

## v2 session and chat routes

| Method | Path | Response | Description |
|---|---|---|---|
| GET | `/api/session` | cursor page `{ data, cursor }` | List sessions; filter with `directory` |
| GET | `/api/session/:id` | `{ data: OCSession }` | Get a session |
| POST | `/api/session` | `{ data: OCSession }` or acknowledgement | Create in body `location.directory` |
| PATCH | `/api/session/:id` | acknowledgement | Update a session title |
| DELETE | `/api/session/:id` | acknowledgement | Delete a session |
| GET | `/api/session/active` | `{ data: Record<sessionID, { type: "running" }> }` | Running-session snapshot |
| GET | `/api/session/:id/message` | cursor page `{ data, cursor }` | List messages |
| GET | `/api/session/:id/message/:messageID` | `{ data: OCMessageWithParts }` | Get message detail |
| POST | `/api/session/:id/prompt` | acknowledgement | Admit a `steer` or `queue` prompt |
| POST | `/api/session/:id/interrupt` | interruption result | Stop a running session |

| GET | `/api/session/:id/diff?from=:messageID` | `{ data: [FileDiff] }` | Selected user turn; omit `from` for newest turn |
| DELETE | `/api/session/:id/revert` | 204 | Clear staged revert |
| POST | `/api/session/:id/revert/stage` | `{ data: Revert }` | Stage `{messageID,files:true}` |
| POST | `/api/session/:id/revert/commit` | 204 | Commit staged revert |
| POST | `/api/session/:id/permission/:requestID/reply` | 204 | `{decision:"once"\|"always"\|"reject"}` |
| GET | `/api/vcs/diff?mode=working` | `{ location, data: [FileDiff] }` | Working-copy patches |

V2 command attachment arrays contain objects (`{uri}`, `{name}`, `{id}` for
files, agents, and skills respectively). Model cost tiers use
`{type:"context",size:...}`. Assistant execution errors use `{type,message,status?}`.

## Legacy v1 endpoints

V1 remains supported for paired legacy servers. The following tables document
that compatibility surface; v2 connections must not use these routes.

### Health

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/global/health` | — | `OCHealthResponse` | Server health check (healthy, version) |

## Sessions

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/session` | — | `[OCSession]` | List all sessions |
| GET | `/session/:id` | — | `OCSession` | Get a single session |
| POST | `/session` | `{ title?, parentID? }` | `OCSession` | Create a new session |
| PATCH | `/session/:id` | `{ title }` | `OCSession` | Update session title |
| DELETE | `/session/:id` | — | `Bool` | Delete a session |
| GET | `/session/status` | — | `[String: OCSessionStatus]` | Status of all sessions (idle/busy/retry) |
| POST | `/session/:id/abort` | `{}` | `Bool` | Abort the running agent in a session |
| POST | `/session/:id/share` | `{}` | `OCSession` | Generate a share link for a session |
| POST | `/session/:id/revert` | `{ messageID, partID? }` | `Session` (legacy: `Bool`) | Revert changes from a specific message |

## Messages

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/session/:id/message` | `?limit=N` | `[OCMessageWithParts]` | List messages in a session |
| GET | `/session/:id/message/:msgID` | — | `OCMessageWithParts` | Get a single message with parts |
| POST | `/session/:id/message` | `OCPromptInput` | `OCMessageWithParts` | Send prompt synchronously (blocking) |
| POST | `/session/:id/prompt_async` | `OCPromptInput` | 204 No Content | Send prompt asynchronously (monitor via SSE) |

### OCPromptInput

```json
{
  "parts": [{ "type": "text", "text": "..." }],
  "model": { "providerID": "...", "modelID": "..." },
  "agent": "optional-agent-id",
  "messageID": null
}
```

## Providers & Config

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/provider` | — | `OCProviderResponse` | List providers, models, defaults, and connected provider IDs |
| GET | `/config` | — | `OCConfig` | Server configuration (current model, provider settings) |

### OCProviderResponse

```json
{
  "all": [{ "id": "anthropic", "name": "Anthropic", "models": { ... } }],
  "default": { "providerID": "anthropic", "modelID": "claude-sonnet-4-20250514" },
  "connected": ["anthropic", "openai"]
}
```

## Agents & Commands

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/agent` | — | `[OCAgent]` | List available agents |
| GET | `/command` | — | `[OCCommand]` | List available slash commands |

## Files

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/file` | `?path=...` | `[OCWorkspaceFileEntry]` | List files for a relative path from the server directory. `path=.` and `path=/` return the current root listing. Absolute paths may return empty results. |

### OCWorkspaceFileEntry

```json
{
  "name": "OpenCoder",
  "path": "OpenCoder",
  "absolute": "/workspace/OpenCode",
  "type": "directory",
  "ignored": false
}
```

## Project & VCS

OpenCode resolves project context per request. In practice, the client can switch the active project by sending either:

- query parameter: `?directory=/absolute/path/to/project`
- header: `x-opencode-directory: /absolute/path/to/project`

This override affects endpoints such as `/project`, `/project/current`, `/path`, `/vcs`, session CRUD, file browsing, and prompt/session operations.

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/project` | — | `[OCProject]` | List all projects |
| GET | `/project/current` | — | `OCProject` | Get the currently active project |
| GET | `/path` | — | `OCPathInfo` | Server paths (state, config, worktree, directory) |
| GET | `/vcs` | — | `OCVCSInfo` | Version control info (current branch) |

## Diffs

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/session/:id/diff` | `?messageID=...` | `[OCFileDiff]` | File diffs for a session (optionally scoped to a message) |

## Permissions

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/permission` | — | `[OCPermissionRequest]` | List pending permission requests |
| POST | `/permission/:id/reply` | `{ reply: "once" \| "always" \| "reject" }` | `Bool` | Approve, always approve, or deny a permission request |

## Questions

| Method | Path | Request | Response | Description |
|--------|------|---------|----------|-------------|
| GET | `/question` | — | `[OCQuestionRequest]` | List pending (unanswered) questions |
| POST | `/question/:id/reply` | `OCQuestionReply` | `Bool` | Reply to a question with selected answers |
| POST | `/question/:id/reject` | `{}` | `Bool` | Reject/dismiss a question |

### OCQuestionReply

```json
{
  "answers": [["selected option 1", "selected option 2"]]
}
```

## SSE (Server-Sent Events)

| Method | Path | Headers | Description |
|--------|------|---------|-------------|
| GET | `/event` | `Accept: text/event-stream` | Real-time event stream for session updates |

### Event Types

| Event Type | Description |
|------------|-------------|
| `server.connected` | Initial connection confirmation |
| `server.heartbeat` | Keep-alive heartbeat |
| `session.status` | Session status change (idle/busy/retry) |
| `session.updated` | Session metadata updated (title, etc.) |
| `message.updated` | New or updated message (user/assistant) |
| `message.part.updated` | Message part created or updated (text, tool, reasoning, step) |
| `message.part.delta` | Incremental text delta for streaming |
| `message.part.removed` | Message part removed |
| `message.removed` | Entire message removed |
| `permission.asked` | Agent requests permission to proceed |
| `question.asked` | Agent asks the user a question with options |
| `question.replied` | Confirmation that a question was answered |
| `question.rejected` | Confirmation that a question was dismissed |

---

**Total: 30 unique endpoints** (27 REST + 1 SSE + 2 raw/debug variants)

Source: `Services/OpenCodeClient.swift`, `Services/SSEClient.swift`
