# Orphaned Workspace sections

Status: **intentionally left in place** (decided 2026-11-05). Do not delete or
"clean up" without first deciding restore vs. delete. Documented during the
interface-design review of the Sessions / Review / Workspace / Settings tabs
(`feature/tab-ui-review`).

## What is orphaned

Three sections in `OpenLens/Views/Workspace/WorkspaceRootView.swift` are fully
implemented but never rendered. The `content` Form is built from
`workspaceIdentitySection`, the inline error section, `sourceControlSection`,
`actionsSection`, `changedFilesSection`, and `filesSection` — nothing else.

| Section  | Code                                                   | Contents                                                                  |
| -------- | ------------------------------------------------------ | ------------------------------------------------------------------------- |
| Activity | `activitySection` + `WorkspaceActivityHeatmap` (~190 lines) | 12-week × 7-day contribution heatmap, Less/More legend, empty state       |
| Insights | `insightsSection` + `openInsights()`                     | Link row to per-session cost/token/model insights                         |
| Commands | `commandsSection`                                        | Searchable workspace-command list, capped at 6 results                    |

## Live wiring that only serves dead UI

- `@State commandSearch`, `filteredCommands`, `hasCommands`, `commandCountLabel`,
  `makeFilteredCommands`, and the `.onChange(of: commandSearch)` handler in
  `body` — all mutate state that no rendered view reads.
- `WorkspaceActivityHeatmap` is self-contained but is only instantiated by the
  dead section.

## Orphaned navigation route (reachability break)

`openInsights()` is the only caller of
`router.navigate(to: .sessionInsights(...))`. With `insightsSection`
unreachable:

- `RouterDestination.sessionInsights` (`Navigation/RouterDestination.swift`)
  has no live navigator.
- `ConnectedRootView` keeps a live destination mapping to `InsightsRootView`.
- `SessionInsightsService` is still constructed and injected in `OpenLensApp`.

The entire Insights feature is currently unreachable from the UI.

## History

- `46e6b61` (Add session pagination and refresh workspace views) — `content`
  last rendered project, source control, actions, changed files, **activity**,
  **insights**, files, **commands**.
- `586976b` (Add GitHub star progress to settings) — `content` was rewritten;
  activity, insights, and commands dropped from the Form. Their code, state,
  and routes were left behind.

## Decision needed

Restore all three in `content`, restore a subset, or delete the sections plus
their state, helpers, the heatmap, and — if deleting Insights — the
`.sessionInsights` route, `InsightsRootView`, and the `SessionInsightsService`
wiring in `OpenLensApp`.

Line numbers drift; grep the symbol names instead.
