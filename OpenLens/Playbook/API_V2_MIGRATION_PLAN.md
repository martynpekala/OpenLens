# OpenCode API v2 migration plan

Status: proposed  
Research date: 2026-09-23  
Scope: OpenLens iOS app, widget intents, and the encrypted remote transport. This document does not change production code.

## Executive summary

OpenLens is predominantly a v1 client today. Most requests in `OpenCodeClient.swift` use unprefixed routes such as `/session`, `/provider`, `/permission`, and `/question`, while `SSEClient.swift` subscribes to `/event`. The lone v2 route already in use is the queued-prompt call to `/api/session/{id}/prompt`; it is currently adapted into the otherwise-v1 client.

The migration is larger than adding `/api`. V2 changes response envelopes, list pagination, prompt admission, session status, location selection, permissions, questions, message projections, errors, and SSE recovery. The official migration guide explicitly identifies the server API as a breaking change and says all v1 server integrations must migrate.[^migration-server]

The chosen approach is permanent dual-protocol support behind the existing `OpenCodeClient` facade, with v2 detected through `GET /api/info` and capabilities verified at runtime. V1 remains supported in this and all subsequent releases. Tests should still pin representative OpenCode/OpenAPI revisions so contract changes are reproducible, but OpenLens will not impose a minimum v2 release or commit. This extends OpenCode's advice to retain the v1 setup while validating v2.[^migration-verify]

Two risks should shape the work:

1. The published v2 HTTP surface calls itself experimental, currently reports OpenAPI version `0.0.1`, and can still change.[^api][^openapi]
2. `/api/event` is explicitly volatile: a slow consumer can overflow the stream, and events emitted while disconnected are missed. REST reconciliation after reconnect is therefore required, not optional.[^event]

## Current OpenLens surface

The current integration is concentrated in a few existing seams; no new `ViewModel` or presenter layer is needed.

| Area | Current implementation | Current contract assumptions |
| --- | --- | --- |
| HTTP | `OpenLens/Services/OpenCodeClient.swift` | Raw v1 payloads; `Bool` action responses; one generic decoder; `x-opencode-directory` header |
| Models | `OpenLens/Models/ServerModels.swift` | v1 session/message/part/provider/config/permission/question/file shapes |
| Events | `OpenLens/Services/SSEClient.swift`, `SSEEventHandler.swift` | `GET /event`; JSON `{type, properties}`; named heartbeat events; message-part deltas |
| App services | `SessionsService`, `MessagesService`, `ProvidersService`, `WorkspaceService`, `InboxService`, `QuestionService`, `ReviewService` | Stable app-facing facade around the v1 client |
| Connection | `ConnectionManager.swift` | `/global/health` returns `{healthy, version}`; project context is restored before connecting SSE |
| Remote | `OpenCodeTransport.swift` and `Tools/openlens-qr-menubar/RemoteSources/OpenCodeForwarder.swift` | The encrypted protocol carries HTTP/SSE bytes, but the Mac relay explicitly allowlists v1 methods and paths, recognizes only `/event` as a stream, and enforces workspace scope through `x-opencode-directory` |
| Widget | `OpenLensActivityWidget/PermissionIntents.swift` | Permission reply route is assembled independently of `OpenCodeClient` |

There is no checked-in `opencode.json(c)`, `.opencode` plugin, or other repository configuration that needs conversion. Project `AGENTS.md` and skill discovery remain supported in v2, so the app migration should stay focused on the server client.[^migration-files]

## Contract changes that affect the app

### Cross-cutting changes

- V2 endpoints live below `/api` and begin with `GET /api/info` and `GET /api/location` for discovery and location resolution.[^api]
- Responses are endpoint-specific. Location-scoped reads commonly return `{location, data}`, session reads commonly return `{data}`, paged reads add a `cursor`, and many mutations return `204 No Content`. A single “decode the body as the requested model” helper is no longer sufficient.[^api]
- Session and message lists are cursor-paginated and ordered. OpenLens must deliberately load all pages required for its session list, activity calendar, transcript, and search behavior; it cannot assume an unbounded array.[^api]
- Location is an explicit `{directory}` reference/query, and location-scoped responses return the canonical location. Replace the implicit `x-opencode-directory` assumption with the documented v2 location parameter/body, while keeping the selected directory as OpenLens state.[^api]
- Errors are typed JSON objects (`400`, `401`, `403`, typed `404`, `409`, `500`, `503`) rather than only a status code. Execution failures also appear inside assistant/tool messages and must remain distinct from HTTP failures.[^openapi]

### Proposed endpoint mapping

This table is a planning map, not a claim that like-named resources have identical schemas.

| OpenLens capability | V1 call today | V2 target / decision |
| --- | --- | --- |
| Server probe | `GET /global/health` | `GET /api/info`; a valid response establishes reachability and supplies the version/identity used for capability negotiation (the published schema has no v1-style `healthy` flag) |
| Resolve project | `GET /path`, `/project/current` | `GET /api/location?location[directory]=...`; retain `GET /api/project` for known projects |
| Sessions | `GET/POST /session`, `GET/PATCH/DELETE /session/{id}` | `/api/session...`; decode envelopes/cursors; after `PATCH` or `DELETE` accept 204 and update/refetch local state |
| Session status | `GET /session/status` | `GET /api/session/active` plus session/timeline events; define how v2 active entries map to OpenLens idle/busy/retry UI |
| Stop generation | `POST /session/{id}/abort` | `POST /api/session/{id}/interrupt`; handle its `interrupted` result and resume semantics |
| Messages | `GET /session/{id}/message[/{messageID}]` | Same resource below `/api`, but paginated/enveloped and represented by the v2 tagged message union |
| Send/queue prompt | `/prompt_async`, `/message`, and one `/api/.../prompt` call | Consolidate on `POST /api/session/{id}/prompt` with required `text` and optional `delivery: steer|queue`; switch the session's agent/model through their dedicated endpoints before admission when the user changed them, and treat the response as durable inbox admission rather than the assistant answer |
| Commands | `GET /command`; `POST /session/{id}/command` | `GET /api/command`; `POST /api/session/{id}/command` with v2 `{name, text, files, agents, skills, delivery}` body |
| Agents | `GET /agent` | `GET /api/agent`, unwrap `{location,data}` |
| Models/providers | `GET /provider` plus `GET /config` | Use `GET /api/model`, `/api/model/default`, and `/api/provider`; stop reconstructing availability/defaults from the v1 provider/config aggregate |
| Files | `GET /file`, `/file/content`, `/file/status` | `GET /api/fs/list`, `GET /api/fs/read/*`, and `GET /api/vcs/status`; review binary-file behavior because `fs.read` returns octet-stream |
| VCS | `GET /vcs` | `GET /api/vcs` for repository info and `/api/vcs/status` for working-copy files |
| Session diff | `GET /session/{id}/diff?messageID=...` | `GET /api/session/{id}/diff`; translate v2 turn-oriented parameters/response into the existing review domain |
| Pending permissions | `GET /permission` | `GET /api/permission/request` by location or `/api/session/{id}/permission` when scoped to one session |
| Permission reply | `POST /permission/{requestID}/reply` | `POST /api/session/{sessionID}/permission/{requestID}/reply` with `{decision: once|always|reject, message?}` and 204 response |
| Questions | `/question` list/reply/reject | Replace with pending forms: `GET /api/form` or session form routes, reply with `POST .../form/{formID}/reply`, cancel with `DELETE .../form/{formID}` |
| Todos | `GET /session/{id}/todo` plus `todo.updated` | No documented v2 todo endpoint exists. Detect support and hide the todo UI when unavailable; do not derive it from undocumented projected content |
| Share session | `POST /session/{id}/share` | No documented v2 share-session operation exists. Detect support and hide the action when unavailable; do not silently keep a v1 route in a v2 connection |
| Revert | one `POST /session/{id}/revert` | V2 stages, clears, and commits a revert with separate operations. Preserve OpenLens's one-tap UX by orchestrating the documented sequence and handling `409 SessionBusy` |
| Events | `GET /event` | `GET /api/event`; parse SSE `event` plus JSON `data`, route by location/session, and reconcile through REST after every gap |

The v2 reference defines the prompt, session, permission, form, filesystem, VCS, and event operations above.[^api] Absence claims for todos and session sharing are based on the published API's complete operation index as of the research date; re-check the pinned schema before implementation.

### Model and UI implications

- `Session.Info` includes explicit location/project/subpath, agent/model, timestamps, outcome, cost/tokens, permissions, and revert state. Replace `OCSession`'s permissive v1 decoder with a v2 DTO mapped into the smaller app domain.
- `Session.Message.Info` is a tagged timeline union, not only user/assistant. It can include agent/model/location switches, synthetic/system/skill/shell messages, compaction, and terminal idle outcomes. Preserve unknown cases so a new server event does not make an entire transcript undecodable.[^api]
- Assistant content is a tagged collection of text, reasoning, and tool items. Map it to the existing `ChatMessage`/part display rather than exposing transport DTOs directly.
- Model identity is structured and can include a variant. Migrate saved selection only after resolving it against `/api/model`; keep unmatched old selections as recoverable preferences rather than deleting them.
- V2 forms are broader than current questions: fields may be string, number, integer, boolean, multiselect, or external URL. Replace `OCQuestionRequest` with a generic, safety-bounded form domain and render supported field types. For an unknown field, show a safe “open in OpenCode”/unsupported state rather than guessing.[^api]
- Permission requests carry `action`, `resources`, save scopes, metadata/source, and session ID. Continue the existing sanitization limits, but update labels to v2 actions (for example `shell`, `subagent`, and `edit`).[^migration-permissions]

## Implementation plan

### Phase 0 — Capture representative contracts and capabilities

1. Select representative v1 and v2 builds for repeatable contract tests, without treating either v2 build as a minimum supported version.
2. Save the representative v2 OpenAPI JSON as a test fixture or record its checksum and source URL. Do not generate production event enums blindly: the public API currently exposes `V2EventEncoded` opaquely, and an upstream issue documents the missing reachable event union.[^event-schema-issue]
3. Capture sanitized golden responses/SSE frames for every OpenLens feature over both direct LAN and the encrypted remote relay.
4. Add a server capability record populated from probes and endpoint behavior. Enable features from detected capabilities rather than a version threshold; report an actionable error only when the server lacks the minimum capabilities required to establish a usable connection.

Exit: the team can reproduce the exact contract used for implementation.

### Phase 1 — Add v2 transport primitives without changing screens

1. Keep `OpenCodeClient` as the app-facing seam. Introduce v2-specific DTO/envelope types in `ServerModels.swift` (or a focused sibling file), not a new presentation architecture.
2. Add request helpers for:
   - endpoint-specific `{data}` and `{location,data}` envelopes;
   - cursor pages;
   - byte bodies for `fs.read`;
   - successful 204 responses;
   - structured API error decoding with status, tag, message, field/service/reference metadata.
3. Encode query items with `URLComponents` rather than interpolating already-escaped strings. In particular, encode the documented deep-object location query consistently.
4. Probe `/api/info` during connection. Select the v2 adapter when the probe succeeds, otherwise use v1. Keep both adapters as permanent supported implementations and apply feature-level capability checks within the selected protocol.
5. Replace the remote relay's v1 route allowlist with the smallest v2 allowlist OpenLens actually needs, and change event-stream recognition from `/event` to `/api/event`. Do not add a blanket `/api/*` rule.
6. Redesign remote workspace enforcement for v2. Strip or validate every caller-supplied location selector, inject the registry-approved directory in the documented query/body shape, and explicitly validate location-bearing session-create/move bodies. Add negative tests for encoded paths, duplicate/conflicting location selectors, and attempts to select an unregistered directory.
7. Update remote relay tests to prove the approved v2 routes, deep-object queries, 204s, binary responses, and long-lived `/api/event` streams pass through while out-of-scope v2 routes and locations remain blocked.

Exit: both transports can call v2 reliably, with no UI behavior changed.

### Phase 2 — Migrate read-only discovery and workspace flows

1. Migrate server info, location/project, agents, commands, models/providers/default model, filesystem, and VCS reads.
2. Map v2 DTOs into the existing `WorkspaceSnapshot`, provider/model selection, connection metadata, and file review domains.
3. Replace config-derived provider filtering with v2 model/provider availability. Treat v1 saved provider/model/variant IDs as migration inputs and validate them against v2 data.
4. Add cursor utilities and migrate session list/message list callers. Explicitly test more than 50 sessions and transcripts longer than one page.
5. Update `API_ENDPOINTS.md` only after v2 behavior is implemented and verified; it currently documents the v1 surface.

Exit: browsing sessions/workspaces and choosing a model/agent works on v2 without prompt execution.

### Phase 3 — Migrate session mutations and prompt admission

1. Migrate create/get/rename/delete. Because rename/delete return 204, optimistically update only where safe and refetch on ambiguity.
2. Consolidate normal prompt, queued prompt, and command submission on v2 admission semantics. If the selected agent/model/variant differs from the session, call the dedicated switch endpoints in a serialized client operation before admitting the prompt. Preserve the UI's local optimistic user message, but reconcile its ID with the admitted inbox item and subsequent projected messages.
3. Decide how OpenLens's current “send while busy” behavior maps to `steer` versus `queue`, and test each explicitly.
4. Replace abort with interrupt and cover idle no-op, active interruption, late assistant events, and queued input.
5. Implement the staged revert sequence behind the existing one-tap domain method; refresh session and diff state after commit.
6. Replace status polling with active-session data plus projected idle outcomes/events. Keep foreground refresh as the authority after missed events.

Exit: a complete chat turn, queue/steer, stop, rename/delete, commands, and revert work without v1 endpoints.

### Phase 4 — Rebuild event handling around reconciliation

1. Point `SSEClient` at `/api/event` and parse standard SSE fields (`event`, `id`, multi-line `data`, comments) independently from the event payload. The HTTP stream envelope's `data` member is itself JSON-encoded, so decode framing, envelope, and domain event as separate steps.
2. Add a thin forward-compatible v2 event envelope: known events get typed payloads; unknown events are logged safely and ignored without terminating the stream.
3. Route all-location events by returned location plus session ID so one workspace cannot mutate another workspace's UI.
4. Preserve existing bounded buffering/backpressure protections. Treat overflow, decode failure, disconnect, app foregrounding, and location shutdown as state-invalidating gaps.
5. On every reconnect/gap, refetch the current session, relevant message pages, active-session status, pending permissions, and pending forms before declaring the UI synchronized. Do not depend on `Last-Event-ID` replay because the official contract says missed events are lost.[^event]
6. Re-record or adapt the extensive `SSEClient` and `ChatStreamBehaviorTests` fixtures to v2 frames and payloads before deleting v1 event cases.

Exit: streaming remains correct after disconnects, event loss, overflow, background/foreground, and unknown new event types.

### Phase 5 — Migrate permissions and forms

1. Store `sessionID` with every pending permission/form because reply endpoints are session-scoped.
2. Update direct app replies, inbox recovery, chat overlays, Micro UI, and `PermissionIntents.swift`; remove independently assembled v1 widget paths.
3. Replace question list/reply/reject with form list/reply/cancel while preserving current size/count/input safety limits.
4. Add UI/domain support for each documented form field. Degrade safely for fields introduced by later server versions.
5. After reconnect, refresh pending permissions/forms to recover interactions missed during the SSE gap.

Exit: every pending interaction can be recovered and answered from chat, inbox, Micro, and widget entry points.

### Phase 6 — Resolve unsupported features and complete dual-protocol support

1. Detect todo and session-sharing capabilities independently. When the connected server does not expose a supported operation, hide the corresponding action; do not derive todos from undocumented message content or silently call a v1 route through a v2 adapter.
2. Run direct and remote parity tests against representative v1 and v2 builds, including authentication failures and all typed HTTP errors.
3. Retain v1 routing, DTOs, and legacy event handling as a supported adapter. Add regression fixtures for both protocols to prevent future v2 work from breaking v1.
4. Update `API_ENDPOINTS.md`, `TECH_DOC_CHAT_LIVE_ACTIVITY.md`, and README/setup instructions to document runtime protocol and capability detection rather than a minimum v2 version.

Exit: release builds select v1 or v2 correctly, never mix routes between adapters, and expose only capabilities supported by the connected server.

## Verification matrix

New tests should use Swift Testing and stay at the existing client/service seams.

| Test layer | Required coverage |
| --- | --- |
| Codable/contract fixtures | Every response envelope; every used tagged union; unknown union/event fallback; typed errors; 204; binary file read |
| URL requests | `/api` paths, path-segment escaping, cursor/order combinations, location deep-object encoding, auth, direct vs remote equivalence |
| Pagination | Empty/one/multiple pages, cursor loop protection, >50 sessions, multi-page transcript, activity aggregation across pages |
| Prompt/session | normal admission, steer, queue, command, duplicate/conflict, interrupt, idle outcome, staged revert, late events |
| SSE | standard framing, comments/heartbeats, split and multi-line data, burst backpressure, overflow, disconnect, reconnect reconciliation, cross-location filtering |
| Interactions | permission once/always/reject, form field types, cancel, missed-event recovery, widget reply |
| Workspace | project/location switch, file list/read, binary rejection/preview, VCS status/diff, remote relay |
| Remote security | exact v2 route allowlist, `/api/event` only in streaming mode, approved-location injection, conflicting/encoded location rejection, request/response size caps |
| Compatibility | v1 and v2 protocol selection, capability changes within v2, migrated saved model selection, and no cross-protocol route leakage |

For each app/widget code increment, run the repository-required command:

```sh
xcodegen generate && xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
```

Visible changes to forms, permissions, connection errors, model selection, or unsupported-feature states also require simulator screenshots.

Because the remote relay changes too, also run its documented macOS suite from `Tools/openlens-qr-menubar/`:

```sh
tuist generate --no-open
xcodebuild -workspace OpenLensRemote.xcworkspace -scheme OpenLensRemote -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Product decisions

1. **No minimum v2 release or commit.** Detect protocol and feature capabilities at runtime. Representative pinned builds remain test fixtures, not compatibility thresholds.
2. **Permanent v1 and v2 support.** The transition release and all following releases must connect to both protocols. Keep their wire contracts isolated behind the existing client seam.
3. **Queue during an active turn.** New input defaults to `delivery: queue`; steering must not happen implicitly.
4. **Hide unsupported todos and sharing.** Detect these capabilities independently and hide actions the connected server does not support. Do not reconstruct todos from undocumented data.
5. **Support all documented form inputs natively.** Implement string fields and options, multiselect, boolean, number, and integer fields. Render external-URL fields as a safe “Open in browser” action. Unknown future field types show an unsupported state directing the user to OpenCode instead of guessing.

## Sources

[^migration-server]: OpenCode, [Migrate from V1 — Server API and clients](https://opencode.ai/v2/docs/migrate-v1/#server-api-and-clients).
[^migration-verify]: OpenCode, [Migrate from V1 — Verify your setup](https://opencode.ai/v2/docs/migrate-v1/#verify-your-setup).
[^migration-files]: OpenCode, [Migrate from V1 — Agent, command, skill, and instruction files](https://opencode.ai/v2/docs/migrate-v1/#agent-files).
[^migration-permissions]: OpenCode, [Migrate from V1 — Permissions and tools](https://opencode.ai/v2/docs/migrate-v1/#permissions-and-tools).
[^api]: OpenCode, [v2 generated HTTP API reference](https://opencode.ai/v2/docs/api).
[^openapi]: OpenCode, [v2 OpenAPI 3.1 document](https://opencode.ai/v2/openapi.json).
[^event]: OpenCode, [v2 API — Subscribe to events](https://opencode.ai/v2/docs/api#tag/event/GET/api/event).
[^event-schema-issue]: OpenCode official repository, [Issue #44911: v2 OpenAPI schema incomplete](https://github.com/anomalyco/opencode/issues/44911).
