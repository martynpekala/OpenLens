# OpenCode Server API Endpoints

All endpoints are relative to the server base URL (e.g. `http://192.168.1.50:4096`).
Authentication uses HTTP Basic Auth via the `Authorization` header when a password is configured.

## Health

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
| POST | `/session/:id/revert` | `{ messageID, partID? }` | `Bool` | Revert changes from a specific message |

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
| POST | `/permission/:id/reply` | `{ response, remember? }` | `Bool` | Approve or deny a permission request |

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
