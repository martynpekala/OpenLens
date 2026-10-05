# 01: Preserve canonical V2 session model, variant, and agent

**What to build:** Continue an existing session with its current server model, reasoning variant, and agent, including changes made from another client.

**Blocked by:** None (can start immediately).

**Status:** done

**Priority:** P1

- [x] Opening, foregrounding, and recovering a V2 session restores canonical model, variant, and agent even before a new assistant message exists.
- [x] Sending an ordinary prompt does not reapply settings inferred from historical messages or saved new-session defaults.
- [x] An explicit local setting change succeeds before a dependent prompt is admitted; failed or obsolete changes cannot silently admit that prompt.
- [x] New-session preferences remain separate from existing-session settings, including unavailable model selections.
- [x] A two-client regression demonstrates an external switch followed by an ordinary phone prompt without overwriting the external settings.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
