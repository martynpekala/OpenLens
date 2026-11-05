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
- Primary buttons: neutral-action convention (`primaryCTAStyle()`,
  `appNeutralAction` FAB) — accent-filled hand-rolled buttons are not used.
- Empty/error states: `ContentUnavailableView` + `primaryCTAStyle()` retry.

## Verification

- Fixture-mode captures: `SIMCTL_CHILD_OPENLENS_SCREENSHOT_MODE=1
  SIMCTL_CHILD_OPENLENS_SCREENSHOT_TAB=<chat|review|workspace|settings>
  xcrun simctl launch <UDID> com.nicolabeghin.OpenLens`, then
  `xcrun simctl io <UDID> screenshot`. Compose labeled before/after boards with
  `.scratch/ui-review/` tooling; expect deltas in the 0.1–6% range for polish
  passes (larger = recheck capture methodology first).
