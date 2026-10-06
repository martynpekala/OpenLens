# 15: Display supported files returned by V2 tools

**What to build:** Inspect supported file content returned by tools rather than losing it when reducing tool output to text.

**Blocked by:** None (can start immediately).

**Status:** done

**Priority:** P2

- [x] Tool content preserves supported file URI, MIME, and name alongside ordinary text.
- [x] Supported images/files have bounded previews or appropriate inspectable actions in existing tool presentation.
- [x] Useful partial file output on a failed tool call is retained.
- [x] Unsupported or inaccessible results remain explicit without discarding other output.
- [x] Reading and rendering respect approved locations, limits, and main-actor responsiveness.
- [x] A recorded tool response verifies the same visible content through direct and Remote transports.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.

**Notes:** Implemented in `dbc37f0`.
- Covered by `V2ToolFileContentTests` (10 tests) and the gateway tests `toolFilesInV2EventsAreCompactedToTheSharedBudgetInsteadOfEndingTheStream` and `toolFilesInTranscriptPagesAreCompactedToTheSharedBudget`. Full suites: iOS 496 passed, gateway 28 passed.
- Shared `ToolResultFileBudget` limits:
  - up to 4 files per tool result
  - 1.5 MiB of inline data per tool result
  - each page or event must fit one Remote message (2 MiB); the largest files are withheld first until it fits
- Direct connections apply the same step, so both transports show the same files.
- Withheld files stay listed with their name and "Too large to show here". Fetching them on demand is not implemented.
- Server `file:` results open only inside the session folder, up to 8 MiB. That limit is checked after the file has been read.
- Screenshots (light and dark) of the tool file row were captured for review.
