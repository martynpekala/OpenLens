# OpenLens interface-design system

Direction: calm, technical instrument for remote agent oversight. Monospaced
data, quiet surfaces, glass chrome as the signature. Chrome sits a tier below
content — group headers use weight, not size, to separate from rows.

## Depth & spacing

- Depth strategy: surface-color shifts + whisper-quiet borders; shadows only
  via `theme.shadow` tokens (`.surfaceShadow()` / `.subtleShadow()`). Dark mode
  leans on borders, not shadows.
- Spacing base: 4 (`OpenLensSpacingTokens`). Screen margin 24 (12 in sidebar).
- Themed canvas everywhere: Forms hide their scroll background and the tab root
  paints `Color.appBackground` — no system grouped gray.

## Hierarchy

- Type: weight + color do the work, size stays near-flat. Row titles 16
  (SessionWorkingTitle, ScaledMetric); group headers 16 semibold (15 sidebar)
  with a secondary 12pt `· count`; metadata 13 rounded secondary.
- Tokens: `sectionLabel` (12 semibold rounded), `rowTitle` (15 medium),
  `rowTitleEmphasized` (15 semibold), `rowSubtitle` (13), `captionRounded` (12).
  Semantic fonts (`.subheadline`, `.footnote`) are fine for Form chrome;
  recurring custom styles must map to a token, one-off literals are allowed.
- Radius: `control` 14 (inputs/buttons), `iconTile` 10, `rowHighlight` 12
  (selection/notice), `listGroup` 16 (grouped option lists), `card` 20.
- Data-ish text (hosts, branches, paths, counts) is monospaced; dynamic numbers
  get `.monospacedDigit()`.

## Color

- Semantic tokens only for meaning: `appSuccess`/`appDanger`/`appWarning` for
  diff +/−, quota thresholds, status badges, notices. Never raw `.green` /
  `.red` / `.orange`.
- Status badge text on a semantic fill: `Color.appBackground` (correct contrast
  in both modes; semantic fills are tuned per mode).
- One accent. User accent (`appUserAccent`) is scoped: Settings, chat bubble,
  send button. Everything else uses the theme accent.

## Component patterns

- `GlassToolbarCapsule` — all toolbar capsules (host, review picker, workspace
  title): h-padding 14, v-padding 6, maxWidth 240, `.glassEffect(.regular, in:
  Capsule())`, `isInteractive` adds `.interactive()`. Content: subheadline
  semibold + caption2 bold chevron when selectable.
- `FileChangeRow` (FileDiffViews.swift) — the one changed-file row everywhere:
  status badge capsule, 14pt medium monospaced path (2-line, middle-trunc),
  themed +/− counts 12pt, chevron. Do not build per-tab variants.
- Sessions list — header and rows share the same leading edge (24pt screen /
  12pt sidebar); no folder icon, no extra row indent. Group separation comes
  from the header's top/bottom padding (12/6), not separators.
- Archived sessions (`ArchivedSessionsView`) mirrors the Sessions row anatomy:
  single-line, title leading with `.frame(maxWidth: .infinity)`, trailing
  metadata (here a relative "archived" date, 13pt rounded) at
  `.firstTextBaseline`, same chevron. Reachable via
  `SCREENSHOT_ARCHIVED_SESSIONS` for fixture validation — this screen had no
  populated fixture before and had silently drifted from the Sessions row.
- Primary buttons: neutral-action convention (`primaryCTAStyle()`,
  `appNeutralAction` FAB) — accent-filled hand-rolled buttons are not used.
- Empty/error states: `ContentUnavailableView` + `primaryCTAStyle()` retry.

## Verification

- Fixture-mode captures. Two mechanisms, and the difference matters: flags in
  the double form (argument *or* `OPENLENS_`-prefixed env key) can be set with
  `SIMCTL_CHILD_`-prefixed environment variables, but **argument-only flags can
  only be passed as positional launch arguments after the bundle id**:
  `xcrun simctl launch <UDID> com.nicolabeghin.OpenLens SCREENSHOT_MODE
  SCREENSHOT_EXECUTION_OUTCOMES`. (`simctl launch` has no `--setenv`.) The
  outcome/unread flags this file's own two-state rule depends on are
  argument-only, so the env-var recipe alone cannot produce the second state —
  prefer positional arguments unless a flag is env-only. Then
  `xcrun simctl io <UDID> screenshot`. Settle 15s after a fresh install — 7s
  once photographed a blank list. Compose labeled before/after boards with
  `.scratch/ui-review/` tooling; expect deltas in the 0.1–6% range for polish
  passes (larger = recheck capture methodology first).
- Conversations-list UI changes require BOTH fixture states captured and
  validated before review — a plain board alone is an invalid review:
  1. default fixture (date rows, no outcome args), and
  2. `SCREENSHOT_EXECUTION_OUTCOMES SCREENSHOT_UNREAD_RESULTS` (succeeded /
     failed / interrupted with relative times, busy shimmer row, unread
     badges on their own line).
  Expect ≈35 content bands for the date variant and ≈46 for the state
  variant (single-server fixture only: the three-server `SCREENSHOT_MULTI_SERVER`
  list has more sections and no band baseline, so judge it by eye); archive both boards under `.scratch/ui-review/`
  (`compare-chat-*-both-states.png` pattern for the two-up board).
- Single-server parity baselines live in `.interface-design/baselines/`
  (`baseline-single-default.png`, `baseline-single-states.png`), captured from
  the single-server fixture before multi-server aggregation existed. The
  sessions list must stay pixel-identical to them while only one server is
  saved; regenerate them only for a deliberate, reviewed design change.

- States not fixture-renderable in the list (waiting-permission/form rows,
  v1 date rows, iPad sidebar selection) are covered by keeping status
  metadata bounded: `ExecutionStatusView(isCompact: true)` never wraps
  (`lineLimit(1)` + `fixedSize`) and yields nothing to the title.

