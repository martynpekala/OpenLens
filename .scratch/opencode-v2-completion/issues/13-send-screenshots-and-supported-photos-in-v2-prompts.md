# 13: Send screenshots and supported photos in V2 prompts

**What to build:** Attach supported phone images to a prompt and retain their representation after admission and history reload.

**Blocked by:** 02: Confirm V2 prompt admission and retry without duplicate work.

**Status:** done

**Priority:** P2

- [x] The composer can select, preview, remove, and submit supported images with text through the existing admission flow.
- [x] Phone bytes use supported data URIs; iOS photo formats are exported to accepted formats such as JPEG or PNG.
- [x] The identical submission and attachment content survive an exact retry without creating new work.
- [x] Model capabilities, complete encoded request size, JSON/Base64 overhead, and Remote's current 2 MiB body limit are checked before submission.
- [x] Relevant incoming image attachments from desktop and history reload use their projected attachment shape and remain visible.
- [ ] A live supported model confirms receipt of the image directly and through Remote; unsupported formats or limits produce an actionable error.
  - Actionable errors are covered by tests; live-model receipt (direct and via Remote) has not been manually verified yet.
- [x] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [x] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [x] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
